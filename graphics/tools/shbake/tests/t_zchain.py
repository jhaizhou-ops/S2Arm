#!/usr/bin/env python3
# 分块共享窗口的连续 deflate 抽取单测（graphics/tools/shbake/nxsh_extract.py scan_zlib / _zlib_try，10-23 暗黑3 Patch2_6_5.cpk 漏抽）：约 0.2 秒，退出 0 = 全过。
# 构造（期望按规则手写，不跑被测实现推期望）：原文 P = 三段 A B C（各 6000 字节，B、C 大量重复前段内容 → 压缩时必然回指前块）。
#   块 0 = 6 字节块头 + 标准 zlib(A)；块 1 = 块头 + 78 da + 裸 deflate(B，以 A 作历史窗口) + adler32(B)；块 2 同理以 B 作窗口压 C。块与块首尾相接。
#   ① _zlib_try 单独解块 1 → 结局「far」（回指过远）；② 以 A 作窗口续解块 1、输入截到块 2 起点 → 解出 B 原样；
#   ③ scan_zlib 扫整份：三块都解开（zlib 流 3、续解 2、续解失败 0）、跨块着色器标记被找到（见 ④）；
#   ④ 在 A 尾 + B 头之间埋一个「控制段魔数 34 12 76 98」：块 1 续解成功才可能在「前块尾巴 + 本块」里看到它，统计「扫到魔数的块」= 1；
#   ⑤ 反证：去掉块 0 → 块 1 前面没有可接的块（不在块链上，按假起点计、不报红），块 2 紧跟没解开的块 1 也接不上 → 假起点 2、红 0；⑥ 块 1 压坏一字节 → 紧跟块 0 却续解不了 → 红 1
import os, sys, zlib, collections
H = os.path.dirname(os.path.dirname(os.path.abspath(__file__))); sys.path.insert(0, H)
import nxsh_extract as X
fail = 0; n = 0
def ck(ok, msg):
    global fail, n
    n += 1; print(('✓ ' if ok else '✗ ') + msg); fail += 0 if ok else 1
import random
rnd = random.Random(7)
A = bytes(rnd.randrange(256) for _ in range(6000))
B = (A[3000:6000] + bytes(rnd.randrange(256) for _ in range(2996)) + b'\x34\x12\x76\x98')[:6000]
B = A[-8:-4] + B[4:]   # B 开头接着 A 的尾巴（同一块内容跨块），并大段重复 A 的后半 → 压缩回指块 0
C = B[1000:5000] + bytes(rnd.randrange(256) for _ in range(2000))
def blk(payload, prev):
    if prev is None: z = zlib.compress(payload, 9)
    else:
        c = zlib.compressobj(9, zlib.DEFLATED, -15, zdict=prev); raw = c.compress(payload) + c.flush()
        z = b'\x78\xda' + raw + zlib.adler32(payload).to_bytes(4, 'big')
    return len(payload).to_bytes(4, 'little') + len(z).to_bytes(2, 'little') + z
b0, b1, b2 = blk(A, None), blk(B, A), blk(C, B)
F = b0 + b1 + b2; s1 = len(b0) + 6; s2 = len(b0) + len(b1) + 6
mv = memoryview(F)
out, used, res = X._zlib_try(mv, s1, len(F))
ck(res == 'far', f'① 单独解块 1 → 回指过远（实得 {res}）')
out, used, res = X._zlib_try(mv, s1, s2 - 6, zdict=A[-32768:])
ck(res == 'ok' and out[:len(B)] == B, f'② 以块 0 输出作窗口续解块 1 → 解出 B 原样（实得 {res}，{len(out)} 字节，相符 {out[:len(B)] == B}）')
seen = []
orig = X.scan_adj
X.scan_adj = lambda path, buf, rows, blobs, stat, tag='adj', owned=frozenset(): seen.append(tag) or 0
st = collections.Counter(); X.scan_zlib('t', F, [], {}, st)
ck(st['zlib 流'] == 3 and st['zlib 块续解（接前块窗口）'] == 2 and st['【红】zlib 块续解失败'] == 0,
   f"③ 整份：zlib 流 3、续解 2、续解失败 0（实得 {st['zlib 流']} / {st['zlib 块续解（接前块窗口）']} / {st['【红】zlib 块续解失败']}）")
ck(len(seen) >= 1, f'④ 跨块的控制段魔数被看到（扫到魔数的块 {len(seen)}，期望 ≥ 1）')
st2 = collections.Counter(); seen.clear(); X.scan_zlib('t', F[len(b0):], [], {}, st2)
ck(st2['【红】zlib 块续解失败'] == 0 and st2['zlib 块续解（接前块窗口）'] == 0, f"⑤ 去掉块 0：块 1、2 接不上前块 → 不续解、不报红（实得 续解 {st2['zlib 块续解（接前块窗口）']}、红 {st2['【红】zlib 块续解失败']}）")
bad = bytearray(F); bad[s1 + 40] ^= 0xFF
st3 = collections.Counter(); X.scan_zlib('t', bytes(bad), [], {}, st3)
ck(st3['【红】zlib 块续解失败'] >= 1, f"⑥ 反证：块 1 压坏一字节 → 紧跟块 0 却续解不了 → 计红（实得 {st3['【红】zlib 块续解失败']}）")
# ⑦ 紧跟前块但不带块头（10-23 异度神剑 3：xbc1 容器头 / zstd 数据里碰巧出现 78 9c）：块 2（回指块 1 的输出）去掉块头、垫 5 字节接在块 0 后，用块 0 作窗口续解不了 → 回指过远但不在块链上：不报红、计「紧跟前块但无块头」
F4 = b0 + b'\x00\x1c\x06\x0c\x06' + b2[6:]
st4 = collections.Counter(); X.scan_zlib('t', F4, [], {}, st4)
ck(st4['【红】zlib 块续解失败'] == 0 and st4['回指过远的假起点（紧跟前块但不在块链上）'] == 1,
   f"⑦ 紧跟前块但无块头 → 不报红、计假起点（实得 红 {st4['【红】zlib 块续解失败']}、无块头假起点 {st4['回指过远的假起点（紧跟前块但不在块链上）']}）")
# ⑧ 前 6 字节碰巧「说得通」但和前块块头声明的终点对不上（异度 3 xbc1 头里的大小字段）：b2 本体前垫 5 字节 + 一个假块头（原长 305、压缩长 47104），离前块 11 字节 → 不报红
F5 = b0 + b'\x00\x00\x00\x00\x00' + (305).to_bytes(4, 'little') + (47104 % 65536).to_bytes(2, 'little') + b2[6:]
st5 = collections.Counter(); X.scan_zlib('t', F5, [], {}, st5)
ck(st5['【红】zlib 块续解失败'] == 0, f"⑧ 假块头对不上前块终点 → 不报红（实得 红 {st5['【红】zlib 块续解失败']}）")
X.scan_adj = orig
print(f't_zchain：{n} 项，失败 {fail}')
sys.exit(1 if fail else 0)
