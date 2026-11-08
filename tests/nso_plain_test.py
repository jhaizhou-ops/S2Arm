#!/usr/bin/env python3
"""tools/nso_plain.py 单测：Python 侧 NSO 读取方遇 ZBIC 统一经 nx_unpack --nso-normalize 规整（不用游戏文件、不要密钥）。
测试帧同 tests/nx_unpack_zbic/Program.cs 的 F3：kinnay zbic 1.0.1（GPL，只当黑盒、只在测试机临时环境跑）压 gen(3, 600) 得到；
期望值 = gen() 的输出本身（不经被测代码算）。帧里字面量权重与三张序列表都是 BIC 表头。"""
import hashlib, os, struct, sys
HERE = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, os.path.join(HERE, '..', 'tools'))
import nso_plain, nso_sym, tempfile

W = ["the","of","and","to","in","is","was","for","on","that","with","as","by","at","from","this","be","or","are","an","which","it","not","have","had"]
def gen(seed, n):   # 同 Program.cs 的 Gen：x = x*1103515245 + 12345 (mod 2^31)，r = x >> 16
    x, o = seed, bytearray()
    while len(o) < n:
        x = (x * 1103515245 + 12345) & 0x7fffffff; r = x >> 16
        o += W[r % len(W)].encode()
        if r % 7 == 0: o += str(r % 1000).encode()
        o += b'\n' if r % 13 == 0 else b' '
    return bytes(o[:n])

F3 = bytes.fromhex('5a424943605801b5090002cf281b056512357310005166f67156a4fd584226147e69a50d2e8a7a210b6fcc1e8d3f20ee78b59520d3f8e960045aa6352e8fe66dde5516c02f455605a5d0596795c5a747910273e070dcbe3a567f84b5fa7290e333a463d05bc7c3c17dee0b053d6c8c04f2f4380ca4b1f105e68f516648fab0583ccb7e4a8c78e367abe00f054f004dc103d8b5c537663ffdf2f219e1f8cce16001ccb7be94d4bc1f107f9a7dc7edcd1b46a809e745f9e1f4b450c019066862d9d1260a06674a45a49a0104dea08779252712882a4318e4aed37d004d3452656e663aa766c6fe95ca914dccafdb106064168888aeede2c9dcf932a0631a713a772b603dda87c5932fabcf02c07f945fdcb1bdaf3b3f9e9ad53966e9c324eb0a8a1ee757adb18493ac7e063459a6d303c8dd4ff3119b3d5562588be7db760b3555')
PLAIN = gen(3, 600)
MOD = b'main\0\0\0\0'

def make(flags, bodies):
    h = bytearray(0x100); h[:4] = b'NSO0'; struct.pack_into('<I', h, 0xC, flags)
    struct.pack_into('<II', h, 0x1C, 0x100, 0); struct.pack_into('<I', h, 0x2C, len(MOD))
    at, mem = 0x100 + len(MOD), 0
    for i, b in enumerate(bodies):
        struct.pack_into('<III', h, 0x10 + 16 * i, at, mem, len(PLAIN)); struct.pack_into('<I', h, 0x60 + 4 * i, len(b))
        h[0xA0 + 32 * i:0xC0 + 32 * i] = hashlib.sha256(PLAIN).digest(); at += len(b); mem += 0x1000
    return bytes(h) + MOD + b''.join(bodies)

ok = bad = 0
def ck(what, cond):
    global ok, bad
    print(('通 ' if cond else '不通 ') + what); ok += bool(cond); bad += not cond

z = make(0xFF, [F3] * 3)
p = nso_plain.plain(z, 'main')
fl = struct.unpack_from('<I', p, 0xC)[0]
segs = [p[struct.unpack_from('<I', p, 0x10 + 16 * i)[0]:][:struct.unpack_from('<I', p, 0x60 + 4 * i)[0]] for i in range(3)]
ck(f'① 0xFF（含 0x40）的 ZBIC NSO 规整：三段 = 合成原文，标志 0xFF → 0x78（实得 {fl:#x}），模块名保留', all(s == PLAIN for s in segs) and fl == 0x78 and p[0x100:0x108] == MOD)
plain_nso = make(0x78, [PLAIN] * 3)
def img(b):
    with tempfile.NamedTemporaryFile(suffix='.nso', delete=False) as f: f.write(b)
    try: return nso_sym.load(f.name)
    finally: os.unlink(f.name)
ck('② 读取方接线：tools/nso_sym.py 的 load（ZBIC 原件）与（不压缩同内容）铺出的映像逐字节相同', img(z) == img(plain_nso))
old = os.environ.get('S2A_NX_UNPACK'); os.environ['S2A_NX_UNPACK'] = '/nonexistent/nx_unpack'
lz = make(0x38, [PLAIN] * 3)
ck('③ 不带 0x80：原样返回同一个对象、不调 nx_unpack（S2A_NX_UNPACK 指向不存在的文件也不报）', nso_plain.plain(lz) is lz)
if old is None: del os.environ['S2A_NX_UNPACK']
else: os.environ['S2A_NX_UNPACK'] = old
broken = bytearray(z); broken[0x108 + 100] ^= 0x20
try: nso_plain.plain(bytes(broken), 'main'); msg = None
except nso_plain.NsoPlainError as e: msg = str(e)
print('   报错：', msg)
ck('④ 负对照：ZBIC 段改坏一字节 → NsoPlainError，带 nx_unpack 的原因', msg is not None and '--nso-normalize' in msg and 'NSO 段 0' in msg)
fake = make(0xBF, [PLAIN] * 3)
try: img(fake); msg = None
except ValueError as e: msg = str(e)
ck('⑤ 负对照：标了 0x80 但段不是 ZBIC 帧 → 读取方报红（ValueError）', msg is not None and '不认识的帧魔数' in msg)
print(f'{"✓" if bad == 0 else "✗"} nso_plain：{ok + bad} 项，不通 {bad}')
sys.exit(1 if bad else 0)
