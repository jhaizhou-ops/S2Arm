#!/usr/bin/env python3
"""Private cross-host checkpoints, not iOS installation artifacts (#704)."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import stat
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from pack.contracts.compare import digest_file, differences
from pack.contracts.validate import ContractError, validate
# 仓库里唯一的 RomFS 遍历（graphics/nvn/tools/romfs_list.py）：检查点含 romfs/，整棵盘点也经它
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "graphics" / "nvn" / "tools"))
import romfs_list

PROFILES = ("extract", "rewrite", "romfs-index")
SUFFIXES = ("patched.bin", "fixups.tsv", "gates.tsv", "sites.tsv", "gaps.tsv", "widen.tsv")
SCHEMA = "s2a.crosshost.prepared.v1"
# Producer bookkeeping is not transport content. Never mutate these files.
SIDECARS = {".stage_unpack", ".stage_rewrite", ".stage_romfsidx",
            "widen_scan.log", "addr_need.log", "nro_exports.log", "nro_to_nso.log", "gpu_drivers.log",
            "romfs_index.log", "unpack.log", "fps_generic.log", "fps_warehouse.log",
            ".root_base", ".root_base_stages", ".root_src"}
REWRITE_OPTIONAL = {"gpu_drivers.tsv", "nro_exports.tsv", "fps.tsv", "widen_verified.tsv", "nro_modules.tsv"}   # nro_modules.tsv：romfs 里 NRO 的改写映像表（宿主 ro LoadNro 按它映射，stage_rewrite.sh）

def _sidecar(name):
    # .stage_<阶段>.deps：main 的阶段实际读入记录（stage_deps_save），跟着已知阶段记号走
    if name.startswith(".stage_") and name.endswith(".deps") and name[:-len(".deps")] in SIDECARS:
        return True
    return name in SIDECARS or bool(re.fullmatch(r"[A-Za-z0-9_-]+\.rewrite\.log", name))

def _stamp(info):
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns,
            info.st_ctime_ns, info.st_mode)



class PreparedError(ValueError):
    """Invalid or incomplete private checkpoint; messages do not echo paths."""


def _name(value):
    if not isinstance(value, str) or not value or any(c in value for c in "\\:\x00\t\r\n"):
        raise PreparedError("非规范检查点路径。")
    if any(part in ("", ".", "..") for part in value.split("/")):
        raise PreparedError("非规范检查点路径。")
    return value


def _identity(value):
    if not isinstance(value, str) or not re.fullmatch("[0-9a-f]{40}", value):
        raise PreparedError("需要完整源码提交身份。")


def _root(root):
    root = Path(root)
    if root.is_symlink() or not root.is_dir():
        raise PreparedError("需要冻结的普通检查点目录。")
    return root.resolve()


def _allowed(name, profile):
    # direct-profile-input.json：解包阶段写的直连配置版本旁注（pack/direct_profile_input.py），是解包快照的一部分；
    #   少了它跨宿主往下出包会在「missing content version」停下，所以跟着 unpack.tsv 一起入账本。
    if name in ("unpack.tsv", "direct-profile-input.json") or name.startswith(("exefs/", "romfs/", "ctl/", "aoc/")):
        return True
    if profile == "romfs-index" and name == "romfs.s2aidx":
        return True
    if profile in ("rewrite", "romfs-index"):
        if name in {"main.npdm", "widen_sites.tsv", "addr_need.tsv"} | REWRITE_OPTIONAL:
            return True
        return any(re.fullmatch(r"[A-Za-z0-9_-]+\." + re.escape(s), name) for s in SUFFIXES)
    return False


def _romfs_store(root):
    """产物根的 romfs 是 RomFS 共享存储软链（pack/roots.sh：../.romfs_store/<款>/<身份>）→ 返回存储里的真目录；不是软链 → None。
    只放行这一种链接：链接原文必须正好是本款存储下的一个身份、目标是真目录（不是软链），其余一律拒绝。"""
    link = root / "romfs"
    if not link.is_symlink():
        return None
    game, _, _ = root.name.partition("@")
    target = os.readlink(link)
    m = re.fullmatch(r"\.\./\.romfs_store/([^/]+)/([^/]+)", target)
    if not game or not m or m.group(1) != game or m.group(2).startswith("."):
        raise PreparedError("检查点不得含链接或特殊文件。")
    store = root.parent / ".romfs_store" / game / m.group(2)
    if store.is_symlink() or not store.is_dir():
        raise PreparedError("检查点不得含链接或特殊文件。")
    return store


def _entries(root):
    """检查点全部条目（路径, 检查点内名字）：不进软链目录；romfs 是合规的共享存储软链时展开成 romfs/…（账本与真目录时逐字节相同）"""
    store = _romfs_store(root)
    out = [(root / e.rel, Path(e.rel).as_posix()) for e in romfs_list.scan(root).entries
           if not (store is not None and Path(e.rel).as_posix() == "romfs")]
    if store is not None:
        out.append((store, "romfs"))
        out += [(store / e.rel, "romfs/" + Path(e.rel).as_posix()) for e in romfs_list.scan(store).entries]
    return sorted(out, key=lambda x: x[1])


def _inventory(root, profile):
    if profile not in PROFILES:
        raise PreparedError("不支持此检查点 profile；首片不支持 pre-metal。")
    paths = {}
    folded = set()
    # Inspect all paths before reading any file content.
    # 同原先 sorted(root.rglob("*"))：全部条目（文件与目录）、不进软链目录；romfs 共享存储软链展开（_entries）
    for path, rel in _entries(root):
        name = _name(rel)
        info = path.lstat()
        if stat.S_ISLNK(info.st_mode) or not (stat.S_ISREG(info.st_mode) or stat.S_ISDIR(info.st_mode)):
            raise PreparedError("检查点不得含链接或特殊文件。")
        key = name.casefold()
        if key in folded:
            raise PreparedError("检查点路径存在跨宿主大小写冲突。")
        folded.add(key)
        if stat.S_ISREG(info.st_mode):
            if _sidecar(name):
                continue
            if not _allowed(name, profile):
                raise PreparedError("检查点含未声明角色文件。")
            paths[name] = path
    required = {"unpack.tsv", "exefs/main", "exefs/main.npdm"}
    if not required <= paths.keys() or not (root / "romfs").is_dir():
        raise PreparedError("缺少基础解包角色。")
    modules = []
    for name, path in paths.items():
        if not name.startswith("exefs/") or name.endswith(".npdm"):
            continue
        module = name.removeprefix("exefs/")
        if not re.fullmatch("[A-Za-z0-9_-]+", module):
            raise PreparedError("模块路径不合法。")
        with path.open("rb") as stream:
            if stream.read(4) != b"NSO0":
                raise PreparedError("ExeFS 模块不是 NSO。")
        if module != "rtld":
            modules.append(module)
    if profile == "rewrite":
        required |= {"main.npdm", "widen_sites.tsv", "addr_need.tsv"}
        required |= {module + "." + suffix for module in modules for suffix in SUFFIXES if suffix != "widen.tsv"}
        optional_widen = {module + ".widen.tsv" for module in modules}
        if not required <= paths.keys():
            raise PreparedError("改写模块文件组不完整。")
        for name in paths:
            if "/" not in name and name not in required and name not in REWRITE_OPTIONAL and name not in optional_widen \
                    and name != "direct-profile-input.json":   # 解包阶段写的直连版本旁注，跟着解包角色走、不是改写产物
                raise PreparedError("改写产物不属于实际模块集合。")
    if profile == "romfs-index" and "romfs.s2aidx" not in paths:
        raise PreparedError("缺少 RomFS 索引。")
    entries = []
    for name, path in paths.items():
        before = path.lstat()
        sha = digest_file(path)
        after = path.lstat()
        if _stamp(before) != _stamp(after) or not stat.S_ISREG(after.st_mode):
            raise PreparedError("检查点读取期间发生变化。")
        entries.append({"path": name, "size": before.st_size, "sha256": sha})
    return entries


def _document(root, profile, source):
    _identity(source)
    entries = _inventory(root, profile)
    by_name = {f["path"]: f for f in entries}
    document = {"schema": "s2a.artifact.v2", "target": "ios-prepared", "files": entries,
                "details": {"schema": SCHEMA, "profile": profile,
                            "provenance": {"sourceCommit": source,
                                           "unpackSha256": by_name["unpack.tsv"]["sha256"]}}}
    validate("artifact", document)
    return document


def _external(root, manifest):
    path = Path(manifest)
    if path.is_symlink() or path.resolve().is_relative_to(root):
        raise PreparedError("账本必须在检查点外，且不得为链接。")
    return path


def _pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise PreparedError("账本含重复 JSON 字段。")
        result[key] = value
    return result


def _load(path):
    try:
        with path.open("r", encoding="utf-8") as stream:
            document = json.load(stream, object_pairs_hook=_pairs)
        validate("artifact", document)
        if set(document) != {"schema", "target", "files", "details"} or document["target"] != "ios-prepared":
            raise PreparedError("需要独立中间检查点账本，不是 iOS 成品。")
        details = document["details"]
        if set(details) != {"schema", "profile", "provenance"} or details["schema"] != SCHEMA:
            raise PreparedError("未知中间检查点合同。")
        provenance = details["provenance"]
        if set(provenance) != {"sourceCommit", "unpackSha256"}:
            raise PreparedError("输入身份不完整。")
        _identity(provenance["sourceCommit"])
        if not isinstance(provenance["unpackSha256"], str) or not re.fullmatch("[0-9a-f]{64}", provenance["unpackSha256"]):
            raise PreparedError("输入摘要身份不合法。")
        for entry in document["files"]:
            if set(entry) != {"path", "size", "sha256"}:
                raise PreparedError("未知文件账本字段。")
            _name(entry["path"])
        return document
    except (ContractError, KeyError, TypeError, json.JSONDecodeError, UnicodeError) as error:
        raise PreparedError("检查点账本结构不合法。") from error


def verify(root, manifest):
    root = _root(root)
    document = _load(_external(root, manifest))
    details = document["details"]
    actual = _document(root, details["profile"], details["provenance"]["sourceCommit"])
    if actual != document:
        raise PreparedError("检查点文件集合、内容或输入身份不一致。")
    return document


def seal(root, manifest, profile, source_commit):
    root = _root(root)
    destination = _external(root, manifest)
    if destination.exists():
        raise PreparedError("不覆盖既有账本。")
    document = _document(root, profile, source_commit)
    data = (json.dumps(document, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode()
    temporary = None
    try:
        fd, temporary = tempfile.mkstemp(prefix=".prepared-", dir=destination.parent)
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        # Re-read frozen input before publication; no completed marker on failure.
        verify(root, temporary)
        os.link(temporary, destination)  # atomic no-clobber publication, same filesystem
    except FileExistsError as error:
        raise PreparedError("不覆盖既有账本。") from error
    finally:
        if temporary is not None:
            Path(temporary).unlink(missing_ok=True)
    return document


def compare(left_root, left_manifest, right_root, right_manifest):
    left = verify(left_root, left_manifest)
    right = verify(right_root, right_manifest)
    if left["details"] != right["details"]:
        raise PreparedError("仅比较相同 profile 和冻结输入身份。")
    a = {f["path"]: {"size": f["size"], "sha256": f["sha256"]} for f in left["files"]}
    b = {f["path"]: {"size": f["size"], "sha256": f["sha256"]} for f in right["files"]}
    delta = differences(a, b)
    return {"equal": not any(delta.values()), "differences": delta}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("seal", "verify"):
        p = commands.add_parser(name)
        p.add_argument("--root", required=True)
        p.add_argument("--manifest", required=True)
        if name == "seal":
            p.add_argument("--profile", required=True)
            p.add_argument("--source-commit", required=True)
    p = commands.add_parser("compare")
    for name in ("left-root", "left-manifest", "right-root", "right-manifest"):
        p.add_argument("--" + name, required=True)
    args = parser.parse_args()
    try:
        if args.command == "seal":
            seal(args.root, args.manifest, args.profile, args.source_commit)
        elif args.command == "verify":
            verify(args.root, args.manifest)
        else:
            result = compare(args.left_root, args.left_manifest, args.right_root, args.right_manifest)
            print(json.dumps({"equal": result["equal"],
                              "counts": {k: len(v) for k, v in result["differences"].items()}}))
            return 0 if result["equal"] else 1
        print(json.dumps({"checkpoint": "verified", "target": "ios-prepared"}))
        return 0
    except (PreparedError, OSError, ContractError):
        print("检查点失败：请在本机检查合同、角色、身份及文件完整性。", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
