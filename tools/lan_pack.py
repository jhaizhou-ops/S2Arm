# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""局域网拉取资源包：服务端与参考客户端共用的部分（只用标准库）。

手机端口径与 tools/push_pack.py 相同（runtime/src/pack_apply.c 不变）：资源包根下 .incoming/<时刻>_<三位序号>.tar 由 App 启动时解开，
单文件镜像（romfs.img / game.img）直接写到最终路径，index.tsv 与 manifest.json 最后写。区别只在方向：推送是电脑写手机，这里是手机向电脑要。

批次 tar 由服务端按「路径列表」现打，字节流是确定的（同一列表、同一份资源包 → 逐字节相同），所以可以按 HTTP Range 续传：
  每个条目 = pax 扩展头（只在路径非 ASCII / 过长时有）+ ustar 头 + 数据 + 补齐到 512；末尾正好 1024 字节全零（tar-ok：512 整倍、末尾 1024 字节全零）。
  mtime / uid / gid 全 0、权限 0644、只有普通文件，pack_apply.c 的 s2a_untar 都认。
"""
from __future__ import annotations

import io
import json
import re
import tarfile

API = "v1"
LIM = 1 << 30                                     # 每批 ≤1 GB，单个超 1 GB 的文件自成一批（同 push_pack.LIM）
IMG = re.compile(r"(^|.*/)romfs\.img$|game\.img")  # 单文件镜像不进 tar（同 push_pack.IMG）
VERSIONS = (2, 3)                                  # 认的 manifest.json 版本（同 push_pack.plan）
END = b"\0" * 1024
_STALE = re.compile(r"\d+_\d{3}\.tar")             # 推送 / 拉取批的名字（同 push_pack.STALE），两边认同一种


def batch_name(name): return bool(_STALE.fullmatch(name))


def json_version(text):
    try: return json.loads(text or "").get("version")
    except (ValueError, AttributeError): return None


def parse_index(text):
    """index.tsv → [(路径, 大小, sha)]；路径不安全的行直接判错（不猜）"""
    out = []
    for line in (text or "").splitlines():
        w = line.split("\t")
        if len(w) != 3: continue
        p, n, h = w
        if not safe(p) or not n.isdigit(): raise ValueError(f"index.tsv 行不对：{line[:120]}")
        out.append((p, int(n), h))
    return out


def safe(p):
    """相对资源包根的安全路径：非空、不以 / 开头、没有 .. 段与反斜杠（同 pack_apply.c safe）"""
    return bool(p) and not p.startswith("/") and "\\" not in p and "\0" not in p and ".." not in p.split("/")


def batches(rows):
    """[(路径, 大小, sha)] → [[行…]…]，每批 ≤1 GB，按原顺序"""
    out, cur, sz = [], [], 0
    for r in rows:
        if cur and sz + r[1] > LIM: out.append(cur); cur, sz = [], 0
        cur.append(r); sz += r[1]
    if cur: out.append(cur)
    return out


def header(path, size):
    """一个条目的头（pax 扩展头按需 + ustar 头），确定性"""
    ti = tarfile.TarInfo(path)
    ti.size, ti.mtime, ti.mode, ti.uid, ti.gid, ti.uname, ti.gname, ti.type = size, 0, 0o644, 0, 0, "", "", tarfile.REGTYPE
    return ti.tobuf(tarfile.PAX_FORMAT, "utf-8", "surrogateescape")


class TarLayout:
    """路径列表的 tar 字节布局：段 = (起点, 长度, 种类, 值)，种类 'b' 字节串、'f' 文件 (路径, 大小)"""

    def __init__(self, rows):
        self.segs, off = [], 0
        for p, n, _ in rows:
            for seg in (("b", header(p, n)), ("f", (p, n)), ("b", b"\0" * ((512 - n % 512) % 512))):
                ln = len(seg[1]) if seg[0] == "b" else n
                if ln: self.segs.append((off, ln, *seg)); off += ln
        self.segs.append((off, len(END), "b", END)); off += len(END)
        self.length = off

    def chunks(self, start, end, opener, bs=1 << 20):
        """[start, end) 范围的字节，按块产出；opener(路径) → 二进制文件对象"""
        for off, ln, kind, val in self.segs:
            if off + ln <= start or off >= end: continue
            a, b = max(start, off) - off, min(end, off + ln) - off
            if kind == "b":
                yield val[a:b]; continue
            with opener(val[0]) as f:
                f.seek(a); left = b - a
                while left:
                    buf = f.read(min(bs, left))
                    if not buf: raise IOError(f"{val[0]} 比索引短（资源包在出包中途被改？）")
                    yield buf; left -= len(buf)


def tar_ok(blob_or_path):
    """推送 / 拉取的批写完整了吗（同 pack_apply.c 契约 ③）"""
    if isinstance(blob_or_path, (bytes, bytearray)):
        b = bytes(blob_or_path); return len(b) >= 1024 and len(b) % 512 == 0 and b[-1024:] == END
    with open(blob_or_path, "rb") as f:
        f.seek(0, io.SEEK_END); n = f.tell()
        if n < 1024 or n % 512: return False
        f.seek(n - 1024); return f.read() == END


def parse_range(h, length):
    """Range: bytes=a-b / a- / -n → (a, b_exclusive)；不认或越界 → None（整份返回）；空范围 → 'bad'"""
    m = re.fullmatch(r"bytes=(\d*)-(\d*)", (h or "").strip())
    if not m or (not m[1] and not m[2]): return None
    if m[1]:
        a = int(m[1]); b = int(m[2]) + 1 if m[2] else length
    else:
        a = max(0, length - int(m[2])); b = length
    b = min(b, length)
    return (a, b) if a < b else "bad"
