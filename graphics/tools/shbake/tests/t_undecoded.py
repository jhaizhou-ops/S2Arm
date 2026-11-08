#!/usr/bin/env python3
# 解不开数据块报告单测（nxsh_extract NXSH_UNDECODED，10-22 第 3 项）：手造四个文件，期望按构造定（不经报告器的判断逻辑）：
#   1 未知容器里 1 MiB 随机字节 → 报 1 段、长 1 MiB
#   2 未知容器里一段 zlib 流（随机词文本压缩，熵高）→ 流被 scan_zlib 解开、区间登记过 → 不报
#   3 BNTX 开头 + 1 MiB 随机字节（贴图，已知媒体）→ 不报
#   4 未知容器里一段 xz 流 → 抽取器认得 xz 就不报，认不得就报（下面按 X 有没有 xz 解码器定期望）
#   5 Wwise AKPK / RE 引擎 TEX / Havok（57 E0 E0 57）/ DDS 开头 + 1 MiB 随机字节 → 不报（10-22 加进已知媒体）
#   6 CRI CPK（本文件手写 @UTF 编码器按公开格式拼，TOC 表另做一份加密版）：3 个条目 = a.usm 随机字节、b.dat 开头 HCA 高位掩码头 + 随机、c.bin 随机
#     → 只报 c.bin 那 1 MiB（起点 = 该条目起点所在的 64 KiB 窗口）；a.usm（扩展名）、b.dat（HCA 头）按目录扣掉
# 用法：t_undecoded.py [shbake 目录]；退出 0 = 全过
import sys, os, zlib, lzma, random, tempfile, collections, glob
D = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
U = tempfile.mkdtemp(); os.environ['NXSH_UNDECODED'] = U
sys.path.insert(0, os.path.abspath(D)); import nxsh_extract as X
fail = 0
def check(ok, what):
    global fail
    print(('✓ ' if ok else '✗ ') + what); fail += 0 if ok else 1
rnd = random.Random(20261022)
words = [''.join(rnd.choice('abcdefghijklmnopqrstuvwxyz') for _ in range(rnd.randint(3, 9))) for _ in range(5000)]
text = ' '.join(rnd.choice(words) for _ in range(400000)).encode()[:3 << 20]
blobs = {
    'rnd.bin': b'PACK' + bytes(12) + rnd.randbytes(1 << 20),
    'zl.bin': b'PACK' + bytes(12) + zlib.compress(text, 9),
    'tex.bntx': b'BNTX' + bytes(12) + rnd.randbytes(1 << 20),
    'xz.bin': b'PACK' + bytes(12) + lzma.compress(text, format=lzma.FORMAT_XZ),
}
import struct
def utf(cols, rows, name='T'):   # @UTF 表：cols = [(列名, 类型)]，全部每行存（标志 0x5x）；类型 4 u32 / 6 u64 / 0xA 字符串
    pool = bytearray(b'<NULL>\0'); so = {}
    def sid(x):
        if x not in so: so[x] = len(pool); pool.extend(x.encode() + b'\0')
        return so[x]
    cb = b''.join(struct.pack('>BI', 0x50 | t, sid(c)) for c, t in cols)
    rb = b''
    for r in rows:
        for (c, t), v in zip(cols, r): rb += struct.pack({4: '>I', 6: '>Q', 0xA: '>I'}[t], sid(v) if t == 0xA else v)
    tn = sid(name); ro = 24 + len(cb); st = ro + len(rb); body = struct.pack('>HHIIIHHI', 1, ro, st, st + len(pool), tn, len(cols), len(rb) // max(1, len(rows)), len(rows)) + cb + rb + bytes(pool)
    return b'@UTF' + struct.pack('>I', len(body)) + body
def enc(b):
    out = bytearray(len(b)); k = 0x5F
    for i, x in enumerate(b): out[i] = x ^ k; k = (k * 0x15) & 0xFF
    return bytes(out)
def cpk(encrypt_toc):
    TOC, CON = 0x800, 0x4000; M = 1 << 20
    ents = [('a.usm', rnd.randbytes(M)), ('b.dat', bytes([0xC8, 0xC3, 0xC1, 0]) + rnd.randbytes(M - 4)), ('c.bin', rnd.randbytes(M))]
    offs = []; body = bytearray(); o = CON
    for n, d in ents: offs.append(o); body += d; o += len(d)
    hd = utf([('ContentOffset', 6), ('TocOffset', 6)], [(CON, TOC)], 'CpkHeader')
    tt = utf([('DirName', 0xA), ('FileName', 0xA), ('FileSize', 4), ('FileOffset', 6)], [('', n, len(d), a - TOC) for (n, d), a in zip(ents, offs)], 'CpkTocInfo')
    if encrypt_toc: tt = enc(tt)
    b = bytearray(CON); b[:16] = b'CPK ' + b'\xff\xff\0\0' + struct.pack('<Q', len(hd)); b[16:16 + len(hd)] = hd
    b[TOC:TOC + 16] = b'TOC ' + b'\xff\xff\0\0' + struct.pack('<Q', len(tt)); b[TOC + 16:TOC + 16 + len(tt)] = tt
    return bytes(b + body), offs[2]
for hdr, nm in ((b'AKPK', 'snd.pck'), (b'TEX\0', 'tex.tex'), (b'\x57\xe0\xe0\x57', 'hk.hkx'), (b'DDS ', 'tex.dds')): blobs[nm] = hdr + bytes(12) + rnd.randbytes(1 << 20)
blobs['p.cpk'], c_off = cpk(False); blobs['q.cpk'], c_off2 = cpk(True)
for name, b in blobs.items(): X.visit(name, b, [], {}, collections.Counter())
runs = collections.defaultdict(list)
for f in glob.glob(os.path.join(U, '*.tsv')):
    for l in open(f):
        p, a, n = l.split('\t')[:3]; runs[p].append((int(a), int(n)))
r1 = runs.get('rnd.bin', [])
check(len(r1) == 1 and r1[0][1] >= (1 << 20) - (1 << 16), f'随机字节：报 1 段、长约 1 MiB（真结果 {r1}）')
check('zl.bin' not in runs, f'zlib 流解开过：不报（真结果 {runs.get("zl.bin")}）')
check('tex.bntx' not in runs, f'BNTX 贴图：不报（真结果 {runs.get("tex.bntx")}）')
has_xz = hasattr(X, 'scan_streams')
check(('xz.bin' in runs) != has_xz, f'xz 流：抽取器{"认得 xz → 不报" if has_xz else "认不得 xz → 报"}（真结果 {runs.get("xz.bin")}）')
for nm in ('snd.pck', 'tex.tex', 'hk.hkx', 'tex.dds'): check(nm not in runs, f'{nm}（AKPK / TEX / Havok / DDS 开头）：不报（真结果 {runs.get(nm)}）')
for nm, co in (('p.cpk', c_off), ('q.cpk', c_off2)):
    r = runs.get(nm, []); W = 1 << 16
    co -= co % W   # 报告按 64 KiB 窗口对齐：段起点 = c.bin 起点所在窗口
    check(len(r) == 1 and r[0][0] == co and r[0][1] >= (1 << 20) - W, f'{nm}（TOC 表{"加密" if nm == "q.cpk" else "明文"}）：只报 c.bin 那段，起点 {co}（c.bin 所在窗口；真结果 {r}）')
print('解不开数据块单测' + ('全过' if not fail else f'有 {fail} 条不通')); sys.exit(1 if fail else 0)
