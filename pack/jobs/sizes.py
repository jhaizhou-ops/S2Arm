"""每款各部分大小 + 存储总览（游戏库结构 v3 P4「查」）。

每款大小记在这款的 game.json 里：sizes = {imageMac, imageIos, saves, cache, sources}（字节）。只在出包 / 打 iPhone 包 / 删除 / 清缓存 /
释放空间 / 移动之后量这一款并写回（refresh），catalog 只读不量；没量过的款由 storageOverview（玩家打开总览时）补量一次。
  imageMac  games/<名>/image/mac
  imageIos  games/<名>/image/ios（容器件 + 资源包）
  saves     games/<名>/saves + save-backups
  cache     games/<名>/build（含 iPhone 出包工作目录 build/ios）+ shader-cache
  sources   这款引用的原件：同一份原件（按 sha256）只算一次；被 n 款引用的原件每款记 大小 // n（各款加起来等于原件大小，不重复算）。
            大小用导入时记的（catalog packages[].size：原件只读、按 sha256 认），不量盘、catalog 每次现算（for_catalog），删了一款，和它共用原件的别款跟着变
量法同 library.disk_bytes：按 (卷, inode) 去重、不跟软链。APFS 克隆不重复算的口径同 library.pack_footprint：出包缓存里还有解包
（build/extract）时，镜像、iPhone 输出和产物根里的 romfs / .romfs_store 是它的克隆，只在 cache 里算一次；解包删了就算进镜像。
Windows（NTFS 无克隆）照实算。
"""
from __future__ import annotations
import os
import shutil
from pathlib import Path

import layout
from core import read

PARTS = ("imageMac", "imageIos", "saves", "cache", "sources")


def _bytes(paths, skip_under=()):
    """这些路径的实占字节（按所在卷分组交 disk_bytes；skip_under 下的克隆目录不算）"""
    from library import CLONED_DIRS, disk_bytes
    by_dev = {}
    for p in paths:
        try:
            by_dev.setdefault(Path(p).lstat().st_dev, []).append(p)
        except OSError:
            pass
    skip = [os.fspath(u) for u in skip_under]
    return sum(disk_bytes(v, dev, skip_names=CLONED_DIRS if skip else (), skip_under=skip) for dev, v in by_dev.items())


def _source_share(gid, games):
    """这款引用的原件（sha256 去重）按引用款数均摊后的字节。用导入时记的大小：原件只读、按 sha256 认，记的就是它的大小，不用量（外接盘没插也算得出）"""
    refs = {}
    for g in games:
        for sha in {p.get("sha256") for p in g.get("packages", []) if p.get("sha256")}:
            refs[sha] = refs.get(sha, 0) + 1
    mine = next((g for g in games if g.get("id", "").upper() == gid), None)
    return sum(int(p.get("size") or 0) // max(1, refs.get(sha, 1))
               for sha, p in {p["sha256"]: p for p in (mine or {}).get("packages", []) if p.get("sha256")}.items())


def measure(c, gid, games=None):
    """量这一款的各部分（字节）；没有文件夹的部分为 0"""
    gid = gid.upper()
    if games is None:
        games = read(c.library / "catalog.json", {}).get("games", [])
    d = layout.find_game(c, gid)
    sizes = dict.fromkeys(PARTS, 0)
    skip = []
    if d is not None:
        build = d / "build"
        if os.name != "nt" and (build / "extract").is_dir():   # 解包还在：别处的 romfs 克隆只在 cache 里算一次
            skip = [d / "image" / "mac", d / "image" / "ios"] + [p for p in build.iterdir() if p.name != "extract"]   # 含 build/ios（iPhone 产物根）
        sizes["imageMac"] = _bytes([d / "image" / "mac"], skip)
        sizes["saves"] = _bytes([d / "saves", d / "save-backups"])
        from library import _build_entries
        sizes["cache"] = _bytes([*_build_entries(c, gid), d / "shader-cache"], skip)   # iPhone 出包日志 build/ios/logs 不算（释放空间的保留项）
        sizes["imageIos"] = _bytes([d / "image" / "ios"], skip)
    sizes["sources"] = _source_share(gid, games)
    return sizes


def refresh(c, gid):
    """量这一款并写回 game.json（作业收尾调）。量不出来不影响作业结果，返回 None"""
    try:
        sizes = measure(c, gid)
        return sizes if layout.write_sizes(c, gid, sizes) else None
    except (OSError, ValueError, TypeError, KeyError):
        return None


def for_catalog(c, gid, games):
    """catalog 每款回的 sizes：目录类四项读 game.json 记的（不量盘；没量过 measured=False、四项为 0），原件按清单现算（不量盘，删 / 导入别款后均摊跟着对）"""
    saved = layout.read_sizes(c, gid) or {}
    out = {k: int(saved.get(k) or 0) for k in PARTS}
    out["sources"] = _source_share(gid.upper(), games)
    out["measured"] = bool(saved)
    return out


# ---- 存储总览（storageOverview 作业）----
# 公共件的位置（P3 把引擎副本、日志、工具缓存挪进默认位置之前的旧位置照样算进来；挪完旧位置不存在，不会重复算）：
#   hosts     <默认位置>/hosts（Mac 宿主、iPhone 壳、引擎副本）+ <私有目录>/engines（引擎副本旧位置）
#   ipa       <默认位置>/S2Arm.ipa、S2Arm.previous.ipa
#   toolCache <默认位置>/tool-cache + 工作目录 cache/、run/（跨游戏工具缓存、按程序号的翻译 / 直连缓存）
#   temp      各存放位置的 temp/
#   logs      <默认位置>/logs + <私有目录>/logs、jobs（任务日志与记录）
SHARED = ("hosts", "ipa", "toolCache", "temp", "logs")


def _outermost(paths):
    """去重并去掉被列表里别的路径包含的（按绝对路径比，不跟链接）"""
    out = []
    for p in dict.fromkeys(Path(os.path.abspath(x)) for x in paths):
        if not any(p.is_relative_to(q) for q in out):
            out = [q for q in out if not q.is_relative_to(p)] + [p]
    return out


def _shared_paths(c):
    L, P, W = c.library, c.private, c.work_root
    temps = [root / "temp" for _, root, ok in layout.locations(c) if ok]
    return {
        "hosts": [L / "hosts", P / "engines"],
        "ipa": [layout.phone_ipa(c), layout.phone_ipa(c, previous=True)],
        # tool-cache 就是现在的工作目录（core.Context.work_root），旧位置（私有目录 / 库内 .s2arm-work 的 cache、run）没迁完时也算；
        #   去掉落在别项里面的，免得同一份量两遍（Windows 实跑：W = L/tool-cache 时总览报成两倍）
        "toolCache": _outermost([L / "tool-cache", W / "cache", W / "run", P / "cache", P / "run", L / ".s2arm-work" / "cache", L / ".s2arm-work" / "run"]),
        "temp": temps,
        "logs": [L / "logs", P / "logs", P / "jobs"],
    }


def overview(c):
    """各存放位置的卷总量 / 剩余与 S2Arm 在那里占的（各款四项 + temp/ + sources/），公共件各占多少，每款 sizes。
    没量过的款这里补量一次并写回（玩家打开总览才量，catalog 不量）"""
    from library import _volume, game_custom
    c.require_library()
    c.begin("统计游戏库占用的空间")
    games = [g for g in c.catalog()["games"] if not g.get("hidden")]
    rows, used = [], {}
    for g in games:
        c.check()
        gid = g["id"].upper()
        where, place = layout.state(c, gid)
        if where == "ok" and layout.read_sizes(c, gid) is None:
            refresh(c, gid)
        s = for_catalog(c, gid, games)
        root = place.parent.parent if where == "ok" else place
        if where == "ok":
            used[str(root)] = used.get(str(root), 0) + sum(s[k] for k in ("imageMac", "imageIos", "saves", "cache"))
        rows.append(dict(gameId=gid, name=game_custom(c, gid)["name"] or g.get("name") or gid, state=where,
                         location=str(root) if root else "", sizes=s))
    shared, under = [], {}
    for k, v in _shared_paths(c).items():
        n = 0
        for p in (p for p in v if os.path.lexists(p)):
            b = _bytes([p]); n += b
            for _, root, ok in layout.locations(c):
                if ok and p.is_relative_to(root):
                    under[str(root)] = under.get(str(root), 0) + b
        shared.append(dict(id=k, bytes=n))
    locations = []
    for lid, root, ok in layout.locations(c):
        row = dict(id=lid, path=str(root), volume=_volume(root), connected=ok, default=root == c.library)
        if ok:   # usedBytes = S2Arm 在这个位置里占的：各款四项 + 原件副本 sources/ + 放在这里的公共件（默认位置的 hosts/、S2Arm.ipa、temp/…）
            disk = shutil.disk_usage(root)
            row.update(totalBytes=disk.total, freeBytes=disk.free,
                       usedBytes=used.get(str(root), 0) + _bytes([root / "sources"]) + under.get(str(root), 0))
        locations.append(row)
    return dict(locations=locations, shared=shared, games=rows)
