#!/usr/bin/env python3
# 相邻扫描的错位幽灵单测（graphics/tools/shbake/nxsh_extract.py scan_adj put，10-27 密特罗德 生存恐惧 515 支幽灵）：约 0.1 秒，退出 0 = 全过。
# 构造（期望按规则手写）：一段字节里依次放三对「控制段 + 紧跟的机器码」（正向），控制段长 0x800、机器码长 0x40（c1 起点 +0x700 = 0x40，末字 NOP、区内有 EXIT）：
#   ① 无代码头、控制段线程组 (0,0,0)：不是计算着色器（接错位的幽灵）→ 丢弃，统计「无头且线程组为 0」= 1；
#   ② 无代码头、线程组 (64,1,1)：真计算着色器 → 收下，阶段 cs；
#   ③ 图形代码头 78563412 + SPH 着色器类型 5（片元）、线程组 (0,0,0)：有头按头定阶段 → 收下，阶段 ps（新规则只管无头的）。
#   期望 2 行（cs、ps 各一），丢弃 1；旧代码 3 行（① 记成 cs）。
# 记录头前缀（rec_hdr，11-02 World War Z .sdc）：[u64 0x20][u64 控制块长 = 控制段长 + 0x18][u64 机器码长][u64 机器码偏移 = 0x20 + 控制块长] 控制段 0x18 字节杂项 机器码（带头、SPH 类型 3 曲面域）、线程组 (0,0,0)：
#   ④ 头四项对得上 → 收 1 行，阶段 ds，键 = sha256(控制段 ‖ 机器码) 前 16 位（测试里独立算）；旧代码 0 行（无头分支把错位 0x18 的字节当机器码、线程组 0 丢弃）；
#   ⑤ 同 ④ 但头里机器码长写错（+8）→ 不认，0 行 ds。
# 记录头 + 无头计算着色器（11-03 WWZ common_nx64_compute 等 .sdc：机器码直接是指令字，没有 78563412 / 79563412 头）、线程组 (64,1,1)、控制块同样多 0x18：
#   ⑥ 机器码像指令区（code_ok）→ 收 1 行，阶段 cs，键 = sha256(控制段 ‖ 机器码) 前 16 位；旧代码 0 行（rec_hdr 只认带头，落到无头分支错位 0x18、code_ok 不过、丢弃）；
#   ⑦ 同 ⑥ 但机器码全 0（不像指令）→ 不认，0 行。
import os, sys, struct, collections
H = os.path.dirname(os.path.dirname(os.path.abspath(__file__))); sys.path.insert(0, H)
import nxsh_extract as X
fail = 0; n = 0
def ck(ok, msg):
    global fail, n
    n += 1; print(('✓ ' if ok else '✗ ') + msg); fail += 0 if ok else 1
CN, DN = 0x800, 0x40
NOP, EXIT = 0x50b0000000070f00, 0xe30000000007000f
def ctl(tg):
    c = bytearray(CN); c[0:8] = bytes.fromhex('3412769801000000')
    struct.pack_into('<I', c, 0x20, CN); struct.pack_into('<I', c, 0x700, DN); struct.pack_into('<I', c, 0x704, DN); struct.pack_into('<3I', c, 0x748, *tg)
    return bytes(c)
def code(head=None, ps=False):
    w = [0] * (DN // 8); w[-2] = EXIT; w[-1] = NOP
    b = bytearray(struct.pack(f'<{len(w)}Q', *w))
    if head is not None:
        b[0:16] = head + bytes(12)
        if ps: struct.pack_into('<I', b, 0x30, 5 << 10)
    return bytes(b)
pad = bytes(0x40)
data = pad + ctl((0, 0, 0)) + code() + pad + ctl((64, 1, 1)) + code() + pad + ctl((0, 0, 0)) + code(bytes.fromhex('78563412'), ps=True) + pad
rows, blobs, st = [], {}, collections.Counter()
X.scan_adj('t.bin', data, rows, blobs, st)
stages = sorted(r[1] for r in rows)
ck(stages == ['cs', 'ps'], f'收下的阶段 = [cs, ps]（实得 {stages}）')
ck(st['无头且线程组为 0（不是计算着色器，丢弃）'] == 1, f"无头且线程组为 0 丢弃 1 支（实得 {st['无头且线程组为 0（不是计算着色器，丢弃）']}）")
ck(len(blobs) == 2, f'收下的着色器 2 支（实得 {len(blobs)}）')
import hashlib
def rec(dn_hdr):
    c = ctl((0, 0, 0)); k = code(bytes.fromhex('78563412')); k = k[:0x30] + struct.pack('<I', 3 << 10) + k[0x34:]
    return pad + struct.pack('<4Q', 0x20, CN + 0x18, dn_hdr, 0x20 + CN + 0x18) + c + bytes([0x0d] * 0x18) + k + pad, c, k
d4, c4, k4 = rec(DN); rows, blobs, st = [], {}, collections.Counter(); X.scan_adj('t4.bin', d4, rows, blobs, st)
want = hashlib.sha256(c4 + k4).hexdigest()[:16]
ck([(r[0], r[1]) for r in rows] == [(want, 'ds')], f'④ 记录头前缀收 1 行 ds、键 {want}（实得 {[(r[0], r[1]) for r in rows]}）')
d5, _, _ = rec(DN + 8); rows, blobs, st = [], {}, collections.Counter(); X.scan_adj('t5.bin', d5, rows, blobs, st)
ck(not [r for r in rows if r[1] == 'ds'], f'⑤ 头里机器码长对不上不认（实得 {[(r[0], r[1]) for r in rows]}）')
def rec_cs(k):
    c = ctl((64, 1, 1))
    return pad + struct.pack('<4Q', 0x20, CN + 0x18, DN, 0x20 + CN + 0x18) + c + bytes([0x0d] * 0x18) + k + pad, c
k6 = code(); d6, c6 = rec_cs(k6); rows, blobs, st = [], {}, collections.Counter(); X.scan_adj('t6.bin', d6, rows, blobs, st)
want = hashlib.sha256(c6 + k6).hexdigest()[:16]
ck([(r[0], r[1]) for r in rows] == [(want, 'cs')], f'⑥ 记录头 + 无头计算着色器收 1 行 cs、键 {want}（实得 {[(r[0], r[1]) for r in rows]}）')
d7, _ = rec_cs(bytes(DN)); rows, blobs, st = [], {}, collections.Counter(); X.scan_adj('t7.bin', d7, rows, blobs, st)
ck(not rows, f'⑦ 记录头后的无头机器码不像指令不认（实得 {[(r[0], r[1]) for r in rows]}）')
print(f't_adj_ghost：{n} 项，失败 {fail}')
sys.exit(1 if fail else 0)
