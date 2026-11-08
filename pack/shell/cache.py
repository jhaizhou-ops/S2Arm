#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Download exactly one shell version; publish a verified root and manifest together."""
from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
import tempfile
from urllib.parse import quote, unquote, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from pack.shell import manifest

MAX_MANIFEST = 16 * 1024 * 1024
_LOCAL = {}   # 本地目录源：下载地址 → 本机文件（ensure 填，_open_url 读）
CHUNK = 64 * 1024


class CacheError(ValueError):
    """A requested shell is unavailable, malformed or differs from its manifest."""


@dataclass(frozen=True)
class CachedShell:
    root: Path
    manifest: Path
    hit: bool


def default_cache_dir():
    explicit = os.environ.get("S2A_SHELL_CACHE")
    if explicit:
        return Path(explicit).expanduser()
    run = Path(os.environ.get("S2A_RUN_ROOT", "~/.s2arm/run")).expanduser()
    return run / "s2arm/cache/shell"   # 与 pack/ipa.sh、tools/gc.sh、tools/shared_paths.tsv 同一个目录


def _base_url(value):
    if not isinstance(value, str) or not value or any(ord(c) < 33 or c == "\\" for c in value):
        raise CacheError("需显式提供合法的 HTTPS 发布根")
    try:
        url = urlsplit(value)
        url.port  # Reject malformed ports even before a cache miss opens a connection.
    except ValueError as error:
        raise CacheError("发布根地址不合法") from error
    if not url.hostname or url.username is not None or url.password is not None or url.query or url.fragment:
        raise CacheError("发布根不能含账号、查询或片段，且必须有主机名")
    if url.scheme != "https" and not (url.scheme == "http" and url.hostname in {"127.0.0.1", "localhost", "::1"}):
        raise CacheError("发布根仅支持 HTTPS，或精确回环地址的 HTTP")
    return value.rstrip("/")


class _SameRootRedirect(HTTPRedirectHandler):
    def __init__(self, base):
        self.base = urlsplit(_base_url(base))

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        target = urlsplit(_base_url(newurl))
        if ((target.scheme, target.netloc) != (self.base.scheme, self.base.netloc)
                or not target.path.startswith(self.base.path.rstrip("/") + "/")
                or any(part in (".", "..") or "\\" in part for part in unquote(target.path).split("/"))):
            raise CacheError("重定向离开指定发布根，拒绝下载")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def _local_root(value):
    """发布根是本机目录（绝对路径，或 file:// 地址）→ 返回 Path；否则 None。内部链路：Mac / mini 出壳后按发布布局放进目录，
    经 ssh 同步到 Windows 出包机本地，出包时从本地目录取（不走网络，校验与 HTTPS 下载同一套）"""
    if not isinstance(value, str) or not value: return None
    if value.startswith("file://"):
        value = unquote(urlsplit(value).path)
        if re.match(r"^/[A-Za-z]:", value): value = value[1:]   # file:///R:/s2a/shells → R:/s2a/shells
    path = Path(value)
    return path if path.is_absolute() and path.is_dir() else None


def _open_url(url):
    local = _LOCAL.get(url)
    if local is not None:
        return local.open("rb")
    # Requests are only constructed by ensure, from the explicitly selected root.
    return build_opener(_SameRootRedirect(url.rsplit("/", 1)[0])).open(Request(url), timeout=30)


def _plain(path, directory):
    info = path.lstat()
    reparse = getattr(info, "st_file_attributes", 0) & getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)
    if stat.S_ISLNK(info.st_mode) or reparse or not (stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode)):
        raise CacheError(f"缓存含链接、重解析点或非普通文件/目录：{path.name}")


def _tree(root):
    _plain(root, True)
    pending = [root]
    while pending:
        for child in pending.pop().iterdir():
            info = child.lstat()
            directory = stat.S_ISDIR(info.st_mode)
            _plain(child, directory)
            if directory:
                pending.append(child)


def _checked(entry, shell_id, hit):
    _plain(entry, True)
    if {p.name for p in entry.iterdir()} != {"root", "manifest.json"}:
        raise CacheError("缓存版本目录必须且只能含 root/ 和 manifest.json")
    root, ledger = entry / "root", entry / "manifest.json"
    _plain(ledger, False)
    _tree(root)
    doc = manifest.require(ledger, shell_id)
    manifest.validate_download_paths(doc["files"])
    manifest.verify(root, ledger)
    return CachedShell(root, ledger, hit)


def _publish(stage, entry, shell_id):
    # Cooperating writers publish nonempty directories, so rename cannot replace
    # another complete version on either Windows or POSIX. Never use replace().
    if os.path.lexists(entry):
        return _checked(entry, shell_id, True)
    try:
        stage.rename(entry)
    except OSError:
        if os.path.lexists(entry):
            return _checked(entry, shell_id, True)
        raise
    return _checked(entry, shell_id, False)


def _payload(url, path, spec):
    digest, count = hashlib.sha256(), 0
    path.parent.mkdir(parents=True, exist_ok=True)
    with _open_url(url) as source, path.open("xb") as output:
        while chunk := source.read(CHUNK):
            count += len(chunk)
            if count > spec["size"]:
                raise CacheError(f"下载文件超过清单长度：{spec['path']}")
            digest.update(chunk)
            output.write(chunk)
        output.flush()
        os.fsync(output.fileno())
    if count != spec["size"] or digest.hexdigest() != spec["sha256"]:
        raise CacheError(f"下载文件大小或 SHA-256 不符：{spec['path']}")


def ensure(shell_id, cache_dir, base_url, offline=False):
    """Return CachedShell(root, manifest, hit); never repair or overwrite bad cache.

    cache_dir=None selects default_cache_dir(). base_url may be None for an
    already cached version or offline request. Importing never accesses network.
    """
    if not isinstance(shell_id, str) or re.fullmatch(r"[0-9a-f]{16}", shell_id) is None:
        raise CacheError("壳编号必须是 16 位小写十六进制")
    try:
        cache_root = Path(cache_dir) if cache_dir is not None else default_cache_dir()
        cache_root = cache_root.expanduser().absolute()
        if os.path.lexists(cache_root):
            _plain(cache_root, True)
        else:
            cache_root.mkdir(parents=True, exist_ok=True)
            _plain(cache_root, True)
        cache_root = cache_root.resolve()
        entry = cache_root / shell_id
        if os.path.lexists(entry):
            return _checked(entry, shell_id, True)
        if offline:
            raise CacheError("离线缓存缺少指定版本")
        local = _local_root(base_url)
        base = str(local).rstrip("/\\") if local is not None else _base_url(base_url)
        prefix = f"{base}/{shell_id}"
        with tempfile.TemporaryDirectory(prefix=f".{shell_id}-", dir=cache_root) as tmp:
            stage = Path(tmp)
            ledger = stage / "manifest.json"
            if local is not None:   # 本地目录源：发布布局同 HTTPS（<根>/<壳编号>/manifest.json、files/<路径>），路径不做 URL 编码
                _LOCAL[f"{prefix}/manifest.json"] = local / shell_id / "manifest.json"
            with _open_url(f"{prefix}/manifest.json") as source:
                data = source.read(MAX_MANIFEST + 1)
            if len(data) > MAX_MANIFEST:
                raise CacheError("壳清单超过 16 MiB 上限")
            ledger.write_bytes(data)
            doc = manifest.require(ledger, shell_id)
            manifest.validate_download_paths(doc["files"])
            root = stage / "root"
            root.mkdir()
            for spec in doc["files"]:
                rel = spec["path"]
                encoded = "/".join(quote(part, safe="") for part in rel.split("/"))
                if local is not None: _LOCAL[f"{prefix}/files/{encoded}"] = local.joinpath(shell_id, "files", *rel.split("/"))
                _payload(f"{prefix}/files/{encoded}", root / rel, spec)
            _checked(stage, shell_id, False)
            return _publish(stage, entry, shell_id)
    except (manifest.ShellError, CacheError) as error:
        raise CacheError(f"壳 {shell_id}：{error}") from error
    except OSError as error:
        # Transport exceptions can contain credentials/proxy URLs. Do not echo them.
        raise CacheError(f"壳 {shell_id}：下载或本地文件操作失败（{type(error).__name__}）") from error


def publish(shell_dir, to):
    """壳目录（<壳目录>/root + manifest.json，pack/shell_build.sh 出）→ 发布布局 <发布根>/<壳编号>/manifest.json + files/<路径>（ensure 读的同一布局）。
    先按清单逐文件核壳；同一编号已发布过就核对后直接返回（内容寻址，不覆盖）。→ 壳编号"""
    shell_dir, to = Path(shell_dir), Path(to)
    ledger = shell_dir / "manifest.json"
    doc = manifest.verify(shell_dir / "root", ledger)
    sid = doc["details"]["shellId"]
    entry = to / sid
    if entry.exists():
        _checked_publish(entry, doc)
        return sid
    to.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=f".{sid}-", dir=to) as tmp:
        stage = Path(tmp) / sid
        for spec in doc["files"]:
            dst = stage.joinpath("files", *spec["path"].split("/"))
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_bytes((shell_dir / "root").joinpath(*spec["path"].split("/")).read_bytes())
        (stage / "manifest.json").write_bytes(ledger.read_bytes())
        _checked_publish(stage, doc)
        try: stage.rename(entry)
        except OSError:
            if not entry.exists(): raise
            _checked_publish(entry, doc)
    return sid


def _checked_publish(entry, doc):   # 发布布局逐文件对清单
    for spec in doc["files"]:
        f = entry.joinpath("files", *spec["path"].split("/"))
        if not f.is_file() or f.stat().st_size != spec["size"] or hashlib.sha256(f.read_bytes()).hexdigest() != spec["sha256"]:
            raise CacheError(f"发布目录 {entry} 里 {spec['path']} 与清单不符")


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "publish":   # cache.py publish --shell <壳目录> --to <发布根>
        pp = argparse.ArgumentParser(description="把壳目录摆成发布布局（内部链路：本机 / mini 目录，ssh 同步到 Windows 出包机）")
        pp.add_argument("--shell", required=True); pp.add_argument("--to", required=True)
        a = pp.parse_args(sys.argv[2:])
        try: print(publish(a.shell, a.to))
        except (manifest.ShellError, CacheError, OSError) as error: print(f"【红】发布壳失败：{error}", file=sys.stderr); return 1
        return 0
    parser = argparse.ArgumentParser(description="按 shellId 下载并复核壳缓存")
    parser.add_argument("--shell-id", required=True)
    parser.add_argument("--cache-dir", type=Path, default=None)
    parser.add_argument("--base-url", help="显式 HTTPS 发布根、精确回环 HTTP，或本机发布目录（绝对路径 / file://）")
    parser.add_argument("--offline", action="store_true")
    parser.add_argument("--json", action="store_true", help="仅输出 UTF-8 JSON，供启动器消费")
    args = parser.parse_args()
    try:
        result = ensure(args.shell_id, args.cache_dir, args.base_url, args.offline)
    except CacheError as error:
        print(f"【红】{error}", file=sys.stderr)
        return 1
    if args.json:
        print(json.dumps({"shellId": args.shell_id, "root": str(result.root),
                          "manifest": str(result.manifest), "hit": result.hit}, ensure_ascii=False))
    else:
        print(f"壳 {args.shell_id} 校验通过（{'缓存命中' if result.hit else '下载完成'}）：{result.root}")
    return 0


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    raise SystemExit(main())
