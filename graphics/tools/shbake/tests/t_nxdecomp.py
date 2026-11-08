#!/usr/bin/env python3
# 通用解压表单测（nxdecomp.py + nxsh_extract 接入，10-22 第 3 项）：期望值按构造定（解码结果 = 原文；抽出的键 = sha256(控制段 ‖ 机器码) 前 16 位）
#   ① 各格式解码 = 原文：gzip / xz / LZMA / LZ4 帧用各自标准压缩器造（独立编码器）；Yay0 / LZ10 / LZ11 / BLZ 没有现成编码器，按公开格式在本文件里手写最小编码器（字面量 + 回指）
#     ——后四种编解码出自同一份格式理解，只证自洽、不证与真机数据一致（我们 15 款里没有用这四种的，实测样本缺）
#   ② 坏数据 / 不自洽 → None（截断的 gzip、长度对不上的 LZ10、乱码当 LZMA）
#   ③ 端到端：着色器对（控制段 + 带头机器码）藏在各格式整文件里、或作为内嵌流夹在未知容器里 → visit 抽出该键；旧代码（没有这张表）抽不出
# 用法：t_nxdecomp.py [shbake 目录]；退出 0 = 全过
import sys, os, gzip, lzma, struct, random, hashlib, collections
D = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
sys.path.insert(0, os.path.abspath(D)); import nxdecomp as Z, nxsh_extract as X
fail = 0
def check(ok, what):
    global fail
    print(('✓ ' if ok else '✗ ') + what); fail += 0 if ok else 1
rnd = random.Random(1022)
text = b''.join(rnd.choice([b'grass ', b'rock ', b'water ', b'shader ', b'\x00\x01\x02\x03']) for _ in range(20000))
# ---- 手写编码器（按公开格式） ----
def enc_lz10(b, t=0x10):
    out = bytearray([t, len(b) & 0xff, len(b) >> 8 & 0xff, len(b) >> 16 & 0xff]); i = 0
    while i < len(b):
        fl_pos = len(out); out.append(0); fl = 0
        for k in range(8):
            if i >= len(b): break
            best = (0, 0)
            for d in range(1, min(0x1000, i) + 1):
                n = 0
                while n < (18 if t == 0x10 else 16) and i + n < len(b) and b[i + n] == b[i + n - d]: n += 1
                if n > best[0]: best = (n, d)
            if best[0] >= 3:
                n, d = best
                if t == 0x10: v = (n - 3) << 12 | (d - 1); out += bytes([v >> 8, v & 0xff])
                else: out += bytes([(n - 1) << 4 | (d - 1) >> 8, (d - 1) & 0xff])   # LZ11 短回指：长度 3..16 编在高 4 位（n-1，取值 2..15）
                fl |= 0x80 >> k; i += n
            else: out.append(b[i]); i += 1
        out[fl_pos] = fl
    return bytes(out)
def enc_yay0(b):
    bits = []; links = bytearray(); lits = bytearray(); i = 0
    while i < len(b):
        best = (0, 0)
        for d in range(1, min(0x1000, i) + 1):
            n = 0
            while n < 17 and i + n < len(b) and b[i + n] == b[i + n - d]: n += 1
            if n > best[0]: best = (n, d)
        if best[0] >= 3: n, d = best; links += struct.pack('>H', (n - 2) << 12 | (d - 1)); bits.append(0); i += n
        else: lits.append(b[i]); bits.append(1); i += 1
    while len(bits) % 32: bits.append(0)
    mask = b''.join(struct.pack('>I', int(''.join(map(str, bits[k:k + 32])), 2)) for k in range(0, len(bits), 32))
    lo = 16 + len(mask); co = lo + len(links)
    return b'Yay0' + struct.pack('>III', len(b), lo, co) + mask + bytes(links) + bytes(lits)
def enc_blz(b):   # BLZ = 对倒序数据做 LZ（回指距离 3..0x1002、长度 3..18），字节流整体再倒过来存，尾部 8 字节头
    rb = b[::-1]; st = bytearray(); i = 0
    while i < len(rb):
        fp = len(st); st.append(0); fl = 0
        for k in range(8):
            if i >= len(rb): break
            best = (0, 0)
            for d in range(3, min(0x1002, i) + 1):
                n = 0
                while n < 18 and i + n < len(rb) and rb[i + n] == rb[i + n - d]: n += 1
                if n > best[0]: best = (n, d)
            if best[0] >= 3:
                n, d = best; v = (n - 3) << 12 | (d - 3); st += bytes([v >> 8, v & 0xff]); fl |= 0x80 >> k; i += n
            else: st.append(rb[i]); i += 1
        st[fp] = fl
    enc = bytes(reversed(st)); hdr = 8; enc_len = len(enc) + hdr; inc = len(b) - len(enc)
    return enc + bytes([enc_len & 0xff, enc_len >> 8 & 0xff, enc_len >> 16 & 0xff, hdr]) + struct.pack('<I', inc)
# ① 解码 = 原文
check(Z.gzip_dec(gzip.compress(text))[0] == text, 'gzip 解开 = 原文')
check(Z.xz_dec(lzma.compress(text, format=lzma.FORMAT_XZ))[0] == text, 'xz 解开 = 原文')
check(Z.lzma_alone_dec(lzma.compress(text, format=lzma.FORMAT_ALONE)) == text, 'LZMA（独立格式）解开 = 原文')
import lz4.frame
check(Z.lz4f_dec(lz4.frame.compress(text))[0] == text, 'LZ4 帧解开 = 原文')
small = text[:3000]
check(Z.lz1x_dec(enc_lz10(small)) == small, 'LZ10 解开 = 原文（手写编码器）')
check(Z.lz1x_dec(enc_lz10(small, 0x11)) == small, 'LZ11 解开 = 原文（手写编码器，短回指）')
check(Z.yay0_dec(enc_yay0(small)) == small, 'Yay0 解开 = 原文（手写编码器）')
check(Z.blz_dec(enc_blz(small)) == small, 'BLZ 解开 = 原文（手写编码器，倒序 LZ）')
# ② 坏数据 → None
check(Z.gzip_dec(gzip.compress(text)[:-20]) is None, '截断的 gzip → None')
bad = bytearray(enc_lz10(small)); bad[1] ^= 0x40
check(Z.lz1x_dec(bytes(bad)) is None, '原长对不上的 LZ10 → None')
check(Z.lzma_alone_dec(b'\x5d' + bytes(rnd.randrange(256) for _ in range(200))) is None, '乱码当 LZMA → None')
# ③ 端到端
CM = bytes.fromhex('3412769801000000'); MG = bytes.fromhex('78563412') + bytes(12)
code = bytearray(0x200); code[:16] = MG; struct.pack_into('<I', code, 0x30, 5 << 10); struct.pack_into('<Q', code, 0x50, 0xe30000000007000f); struct.pack_into('<Q', code, 0x58, 77 | 1 << 40); struct.pack_into('<Q', code, 0xf8, 0x50b0000000070f00)
ctl = bytearray(0x880); ctl[:8] = CM; struct.pack_into('<I', ctl, 0x20, 0x880); struct.pack_into('<I', ctl, 0x704, 0x200); struct.pack_into('<I', ctl, 0x700, 0x100); ctl[0x100] = 77
pair = b'MODEL' + bytes(27) + bytes(ctl) + bytes(code); K = hashlib.sha256(bytes(ctl) + bytes(code)).hexdigest()[:16]
cases = {'整文件 gzip': gzip.compress(pair), '整文件 xz': lzma.compress(pair, format=lzma.FORMAT_XZ), '整文件 LZMA': lzma.compress(pair, format=lzma.FORMAT_ALONE),
         '整文件 LZ4 帧': lz4.frame.compress(pair), '整文件 LZ11': enc_lz10(pair, 0x11), '整文件 Yay0': enc_yay0(pair),
         '内嵌 gzip': b'PACK' + bytes(60) + gzip.compress(pair) + bytes(64), '内嵌 xz': b'PACK' + bytes(60) + lzma.compress(pair, format=lzma.FORMAT_XZ) + bytes(64),
         '内嵌 LZ4 帧': b'PACK' + bytes(60) + lz4.frame.compress(pair) + bytes(64)}
for name, blob in cases.items():
    rows = []; X.visit('t.bin', blob, rows, {}, collections.Counter())
    check(K in {r[0] for r in rows}, f'{name}：抽出键 {K}（真结果 {sorted({r[0] for r in rows})}）')
print('通用解压表单测' + ('全过' if not fail else f'有 {fail} 条不通')); sys.exit(1 if fail else 0)
