#!/usr/bin/env python3
# 通用解压单测（nxsh_extract 10-22：新 6 款静态扫描解不开的四处）：手造数据，期望值按格式定义手算（键 = sha256(控制段 ‖ 机器码) 前 16 位）。
#   1 zstd 带字典（王国之泪 ZsDic）：字典放资源里，帧头写字典号 → find_zsdicts 收齐后解开、抽出着色器
#   2 大文件里出现过 BNSH 也照扫压缩流 + zstd 帧头不写原长（大乱斗 data.arc）：work_zlib 分段扫出
#   3 CRILAYLA（P5R CPK）：手写编码器造字面量 + 回指，scan_crilayla 解开、抽出着色器
#   4 控制段 / 机器码分表存放（异度之刃3）：两段控制段挨着、机器码按同序挨着放在后面，长度不同 → 各配各的，不串
# 旧代码反证：1 解不开（zstd 失败）、2 BNSH 文件不扫流 / 不写原长的帧跳过、3 没有 scan_crilayla、4 两段都记丢弃
# 用法：t_unpack_generic.py [shbake 目录]（缺省本文件上一级）；退出 0 = 全过
import sys, os, struct, hashlib, tempfile, subprocess, collections, shutil
D = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
sys.path.insert(0, os.path.abspath(D)); import nxsh_extract as X
CM = bytes.fromhex('3412769801000000'); MG = bytes.fromhex('78563412') + bytes(12)
NOP, EXIT = 0x50b0000000070f00, 0xe30000000007000f
def shader(ty, seed, n=0x200, c1o=0x100):   # ty：1 vs / 5 ps；机器码过 code_ok：区内有 EXIT、指令区（c1o 之前）末字是 NOP
    code = bytearray(n); code[:16] = MG; struct.pack_into('<I', code, 0x30, ty << 10)
    struct.pack_into('<Q', code, 0x50, EXIT); struct.pack_into('<Q', code, 0x58, seed | 1 << 40); struct.pack_into('<Q', code, c1o - 8, NOP)
    ctl = bytearray(0x880); ctl[:8] = CM; struct.pack_into('<I', ctl, 0x20, 0x880); struct.pack_into('<I', ctl, 0x704, n); struct.pack_into('<I', ctl, 0x700, c1o); ctl[0x100] = seed & 0xff
    return bytes(ctl), bytes(code)
def key(ctl, code): return hashlib.sha256(ctl + code).hexdigest()[:16]
fail = 0
def check(ok, what):
    global fail
    print(('✓ ' if ok else '✗ ') + what); fail += 0 if ok else 1
def keys(rows): return sorted({r[0] for r in rows})
T = tempfile.mkdtemp()
A, B = shader(1, 7), shader(5, 9, 0x300, 0x180)
pair = A[0] + A[1]   # 正向带头：控制段后紧跟带 78563412 头的机器码
# 1 zstd 带字典
samp = os.path.join(T, 'samp'); os.makedirs(samp)
for i in range(64): open(os.path.join(samp, f'{i}'), 'wb').write((f'layer {i} grass rock water ' * 40).encode() + bytes([i]) * 64)
dic = os.path.join(T, 'd.zsdic'); subprocess.run(['zstd', '-q', '--train', '-o', dic, '--maxdict=4096'] + [os.path.join(samp, f) for f in os.listdir(samp)], check=True)
R = os.path.join(T, 'romfs'); os.makedirs(R); shutil.copy(dic, os.path.join(R, 'ZsDic.zsdic'))
raw = os.path.join(T, 'm.bin'); open(raw, 'wb').write(b'MODEL' + bytes(27) + pair)
subprocess.run(['zstd', '-q', '-f', '-D', dic, raw, '-o', os.path.join(R, 'm.bin.zs')], check=True)
zd = os.path.join(T, 'zd'); nd = X.find_zsdicts([R], zd) if hasattr(X, 'find_zsdicts') else 0
os.environ['NXSH_ZSDICT'] = zd; X._zd = None
rows, st = [], collections.Counter(); X.visit('m.bin.zs', open(os.path.join(R, 'm.bin.zs'), 'rb').read(), rows, {}, st)
check(nd == 1 and keys(rows) == [key(*A)], f'字典 zstd：收到字典 1 本、解开抽出 1 个键（期望 {key(*A)}）：真结果 字典 {nd}、键 {keys(rows)}、统计 {dict(st)}')
# 2 BNSH + 帧头不写原长的 zstd 帧，走大文件分段（work_zlib）
fr = os.path.join(T, 'fr.bin'); open(fr, 'wb').write(b'MODEL' + bytes(27) + B[0] + B[1])
subprocess.run(['zstd', '-q', '-f', '--no-content-size', fr, '-o', fr + '.zs'], check=True)
big = os.path.join(T, 'big.arc'); open(big, 'wb').write(b'ARC0' + bytes(60) + b'BNSH\0\0\0\0' + bytes(56) + open(fr + '.zs', 'rb').read() + bytes(64))
od = os.path.join(T, 'o2'); os.makedirs(os.path.join(od, 'src'))
r2, s2 = X.work_zlib((T, big, 0, os.path.getsize(big), od))
check(keys(r2) == [key(*B)], f'大文件里有 BNSH、zstd 帧头不写原长：分段扫出 1 个键（期望 {key(*B)}）：真结果 {keys(r2)}、统计 {dict(s2)}')
# 3 CRILAYLA：字面量 + 回指（长度 3）。编码器：输出从尾往前产出，位流从压缩区尾往前读、字节内高位在前
def crilayla(body, hdr):
    bits = []; out = body[::-1]; i = 0
    def put(v, n): bits.extend((v >> (n - 1 - k)) & 1 for k in range(n))
    while i < len(out):
        if i >= 3 and i + 3 <= len(out) and out[i:i + 3] == out[i - 3:i]:   # 与刚产出的 3 字节相同 → 回指：src = oend - done + r + 3，取 r = 0 指向前 3 个
            put(1, 1); put(0, 13); put(0, 2); i += 3
        else: put(0, 1); put(out[i], 8); i += 1
    bits += [0] * (-len(bits) % 8)
    byts = bytes(int(''.join(map(str, bits[k:k + 8])), 2) for k in range(0, len(bits), 8))
    comp = byts[::-1]
    return b'CRILAYLA' + struct.pack('<II', len(body), len(comp)) + comp + hdr
hdr = b'HDR!' + bytes(0xfc); body = b'xyzxyzxyz' + bytes(23) + pair
cri = b'CPK ' + bytes(28) + crilayla(body, hdr) + bytes(16)
if hasattr(X, 'scan_crilayla'):
    r3, s3 = [], collections.Counter(); X.scan_crilayla('t.cpk', cri, r3, {}, s3)
else: r3, s3 = [], collections.Counter({'没有 scan_crilayla': 1})
check(keys(r3) == [key(*A)] and s3.get('CRILAYLA') == 1, f'CRILAYLA（字面量 + 回指）：解开 1 段、抽出 1 个键（期望 {key(*A)}）：真结果 {keys(r3)}、统计 {dict(s3)}')
# 4 分表：控制段 A、B 挨着，后面填充 0x100，再放机器码 A、B（长度 0x200 / 0x300）
tbl = b'TBL0' + bytes(12) + A[0] + B[0] + bytes(0x100) + A[1] + B[1] + bytes(32)
r4, s4 = [], collections.Counter(); X.scan_adj('t.wismt', tbl, r4, {}, s4)
check(keys(r4) == sorted([key(*A), key(*B)]) and not s4.get('相邻但机器码不像指令（丢弃）'), f'控制段 / 机器码分表：配出 2 个键且没串（期望 {sorted([key(*A), key(*B)])}）：真结果 {keys(r4)}、统计 {dict(s4)}')
# 4b 越过下一个头的不配（着色器线审）：控制段要 0x300 字节机器码，表里第一个头后面只有 0x200 就到了下一个头 → 不能把两段机器码拼成一段配上
Bl, Bs = shader(5, 11, 0x300, 0x180), shader(1, 12, 0x200, 0x100)
tb2 = b'TBL1' + bytes(12) + Bl[0] + b'\xff' * 0x200 + Bs[1] + Bs[1] + bytes(32)   # 控制段 Bl（要 0x300），后面两个 0x200 的机器码头
r5, s5 = [], collections.Counter(); X.scan_adj('t2.wismt', tb2, r5, {}, s5)
check(not r5 and s5.get('相邻但机器码不像指令（丢弃）') == 1, f'分表：控制段要 0x300、表里每段 0x200 → 不跨头硬配，记丢弃 1：真结果 键 {keys(r5)}、统计 {dict(s5)}')
shutil.rmtree(T)
print(f'通用解压单测：{"全过" if fail == 0 else f"{fail} 项不过"}'); sys.exit(1 if fail else 0)
