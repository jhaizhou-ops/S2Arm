"""UE3 package chunk tables in translator/shader_split.py on synthetic bytes (no game data); the shell entry is shader_split_ue3_test.sh.

11-05 Mortal Kombat 11: an n = 1 "table" inside a name record pointed at an embedded {tag, 0, 0x20000, 0}; ue3_chunk divided by its block size 0 and
the whole extraction died with ZeroDivisionError. Expected values are written by hand: a package whose only table is that false one comes back as it is,
a real table still inflates to prefix + payload, a chunk header that is not a chunk is a [RED] exit, never a ZeroDivisionError."""
import hashlib
import os
from pathlib import Path
import shutil
import struct
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "translator"))
TAG = struct.pack("<I", 0x9E2A83C1)
fails = 0


def check(name, want, got):
    global fails
    ok = want == got
    fails += not ok
    print(f"{'✓' if ok else '✗'} {name}：期望 {want}，实 {got}")


def outcome(f, *a):
    try: r = f(*a); return ("值", hashlib.sha256(r).hexdigest()[:12] if isinstance(r, bytes) else r)
    except SystemExit as e: return ("红", str(e).startswith("[RED]"))
    except ZeroDivisionError: return ("除零", None)


with tempfile.TemporaryDirectory(prefix="s2a-ue3-") as d:
    profile = Path(d) / "profile"; profile.mkdir()
    shutil.copyfile(ROOT / "tests/fixtures/shader_split_reuse/shader_split_reuse_profile.tsv", profile / "game.tsv")
    os.environ["DM_GAME"] = str(profile)
    import lz4.block
    import shader_split as ss

    # ① MK11 形状：包头 tag + 0x009d0301（不是整包压缩）；名字记录里 n = 1、条目 {0x80, 0, 0x80, 0}；0x80 处嵌着 {tag, 0, 0x20000, 0}
    fake = bytearray(0x100); fake[0:8] = TAG + bytes.fromhex("01039d00")
    struct.pack_into("<I4I", fake, 0x20, 1, 0x80, 0, 0x80, 0)
    fake[0x80:0x90] = TAG + struct.pack("<3I", 0, 0x20000, 0)
    fake = bytes(fake)
    check("假块表（块大小 0、大小 0）：不当块表，整包原样返回", ("值", hashlib.sha256(fake).hexdigest()[:12]), outcome(ss.ue3_package, fake, "/fake.xxx"))
    check("块头不是块（块大小 0）：ue3_chunk 报红、不除零", ("红", True), outcome(ss.ue3_chunk, fake, 0x80, "/fake.xxx"))

    # ② 真块表照旧：前缀 0x40 字节 + 一个块（块大小 0x20000、一块 LZ4）→ 前缀 + 原文
    payload = bytes(range(256)) * 40
    block = lz4.block.compress(payload, store_size=False)
    head = bytearray(0x40); head[0:8] = TAG + bytes.fromhex("01039d00")
    struct.pack_into("<I4I", head, 0x10, 1, 0x40, len(payload), 0x40, 16 + 8 + len(block))
    chunk = TAG + struct.pack("<3I", 0x20000, len(block), len(payload)) + struct.pack("<II", len(block), len(payload)) + block
    real = bytes(head) + chunk
    check("真块表：解成前缀 + 原文", ("值", hashlib.sha256(bytes(head) + payload).hexdigest()[:12]), outcome(ss.ue3_package, real, "/real.xxx"))

print(f"{'✓' if not fails else '✗'} shader_split_ue3_test：{fails} 处不符")
sys.exit(1 if fails else 0)
