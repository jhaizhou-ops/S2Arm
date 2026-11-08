#!/usr/bin/env python3
# RE 引擎程序表单测（nxsh_extract.scan_sdf + re_pak 补丁链，10-21 pair）：手搓 SDF / KPKA，期望值按格式定义手算（键 = sha256(控制段 ‖ 机器码) 前 16 位）。
# 旧代码反证：旧抽取没有 scan_sdf / re_pak，第 1 项拿不到 <文件>#sdf 来源（只有相邻扫描的 @adj），第 4 项把补丁换掉的旧版也抽出来。
# 用法：t_sdf.py [shbake 目录]（缺省本文件上一级）；退出 0 = 全过
import sys, os, re, struct, hashlib, zlib, tempfile, subprocess, shutil
D = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
sys.path.insert(0, os.path.abspath(D)); import nxsh_extract as X
CM = bytes.fromhex('3412769801000000'); MG = bytes.fromhex('78563412') + bytes(12)
def shader(ty, seed, n=0x200):   # ty：1 vs / 5 ps / 0 计算（无头）
    code = bytearray(n)
    if ty: code[:16] = MG; struct.pack_into('<I', code, 0x30, ty << 10)
    code[0x40:0x48] = struct.pack('<Q', seed)
    ctl = bytearray(0x880); ctl[:8] = CM; struct.pack_into('<I', ctl, 0x20, 0x880); struct.pack_into('<I', ctl, 0x704, n); ctl[0x100] = seed & 0xff
    return bytes(ctl), bytes(code)
def key(ctl, code): return hashlib.sha256(ctl + code).hexdigest()[:16]
def sdf(recs, blobs):   # recs：[(名字, {阶段号: 块号})]；阶段号 0 vs … 4 ps 5 cs
    n = len(recs); names = b''.join(nm.encode() + b'\0' for nm, _ in recs); so = 0x10 + n * 0x108
    bo = (so + len(names) + 7) & ~7; offs = []; body = b''
    for ctl, code in blobs: offs.append(bo + len(body)); body += struct.pack('<II', len(ctl), len(code)) + ctl + code
    out = bytearray(b'SDF\0' + struct.pack('<HHQ', 1, n, so + len(names))); p = so
    for nm, st in recs:
        r = bytearray(0x108); struct.pack_into('<Q', r, 0, p); p += len(nm) + 1
        for si, b in st.items(): struct.pack_into('<Q', r, 0x10 + 8 * si, offs[b])
        out += r
    out += names; out += bytes(bo - len(out)); out += body
    return bytes(out)
fail = 0; n = 0
def check(ok, what):
    global fail, n
    n += 1; print(('✓ ' if ok else '✗ ') + what); fail += 0 if ok else 1
A, B, C, Dc = shader(1, 1), shader(5, 2), shader(5, 3), shader(0, 4)
f1 = sdf([('ShadowStatic', {0: 0, 4: 1}), ('TSShadowStatic', {0: 0, 4: 2}), ('PreTransformCS', {5: 3})], [A, B, C, Dc])
# 1) 每条记录 = 一个程序：来源 <文件>#sdf、变体号 = 记录号；共用的顶点块两条记录各记一次；相邻扫描不重复认领
rows, blobs, stat = [], {}, __import__('collections').Counter()
X._scan_blob('t.sdf', f1, rows, blobs, stat)
want = sorted([(key(*A), 'vs', 't.sdf#sdf|ShadowStatic', 0), (key(*B), 'ps', 't.sdf#sdf|ShadowStatic', 0), (key(*A), 'vs', 't.sdf#sdf|TSShadowStatic', 1), (key(*C), 'ps', 't.sdf#sdf|TSShadowStatic', 1), (key(*Dc), 'cs', 't.sdf#sdf|PreTransformCS', 2)])
check(sorted(rows) == want, f'三条记录 → 5 条阶段记录（vs+ps、vs+ps、cs），来源 #sdf|记录名、变体号 = 记录号：真结果 {len(rows)} 条，{"一致" if sorted(rows) == want else rows}')
# 2) 记录指的块阶段对不上（vs 槽指向片元）：整个文件不认，退回相邻扫描（不出 #sdf）
f2 = sdf([('Bad', {0: 1})], [A, B])
rows2 = []; X._scan_blob('b.sdf', f2, rows2, {}, stat)
check(not any('#sdf' in r[2] for r in rows2) and stat['SDF 记录对不上'] == 1, f'vs 槽指向片元块 → 不认（#sdf 0 条、记录对不上 1）：真结果 #sdf {sum("#sdf" in r[2] for r in rows2)} 条、记录对不上 {stat["SDF 记录对不上"]}')
# 3) KPKA 补丁链：同一路径哈希后读的盖掉先读的；deflate 条目解出原文
def kpka(path, ents):   # ents：[(哈希, 数据, 压缩 0/1)]
    hdr = b'KPKA' + struct.pack('<BBHI', 4, 0, 0, len(ents)) + b'\0' * 4; off = 16 + 48 * len(ents); toc = b''; data = b''
    for h, d, c in ents:
        s = d if c == 0 else (lambda o: o.compress(d) + o.flush())(zlib.compressobj(9, zlib.DEFLATED, -15))
        toc += struct.pack('<IIqqqqQ', h & 0xffffffff, h >> 32, off + len(data), len(s), len(d), c, 0); data += s
    open(path, 'wb').write(hdr + toc + data)
import re_pak
T = tempfile.mkdtemp(); R = os.path.join(T, 'romfs'); os.makedirs(R)
H1, H2 = 0x1111111122222222, 0x3333333344444444
old_v = sdf([('ShadowStatic', {0: 0, 4: 1})], [A, B]); new_v = sdf([('ShadowStatic', {0: 0, 4: 1})], [A, C])
kpka(os.path.join(R, 're_chunk_000.pak'), [(H1, old_v, 0), (H2, f1, 1)])
kpka(os.path.join(R, 're_chunk_000.pak.patch_001.pak'), [(H1, new_v, 1)])
ch = re_pak.chains([os.path.join(R, f) for f in os.listdir(R)]); E, sh = re_pak.resolve(next(iter(ch.values())))
got = {h: os.path.basename(p) for p, h, *_ in E}
check(sh == 1 and got == {H1: 're_chunk_000.pak.patch_001.pak', H2: 're_chunk_000.pak'}, f'补丁链：H1 取补丁版、H2 取基础包、换掉旧版 1 条：真结果 {got}，旧版 {sh}')
e2 = [e for e in E if e[1] == H2][0]
check(re_pak.read(open(e2[0], 'rb'), *e2[2:]) == f1, 'deflate 条目解出原文')
# 4) 整条抽取：补丁换掉的旧版（片元 B）不进 rows，新版（片元 C）进；基础包里没被换掉的文件照常
O = os.path.join(T, 'out'); r = subprocess.run([sys.executable, os.path.join(D, 'nxsh_extract.py'), O, R], capture_output=True, text=True, env=dict(os.environ, J='2'))
# 抽取失败先把它的 stderr 打出来；缺 lz4（Unity 扫描 import lz4.block）单独报缺依赖、不并进 H1 条数断言（11-01 审计 P2-80：原先显示成「H1 记录 无」，缺包和真回归看着一样）
NO_LZ4 = r.returncode != 0 and re.search(r"No module named '?lz4", r.stderr)
if r.returncode != 0: print(f'  抽取 nxsh_extract.py 退出 {r.returncode}，stderr 末尾：\n' + '\n'.join('    ' + l for l in r.stderr.strip().splitlines()[-8:]))
if NO_LZ4:
    print(f'✗ 缺依赖 lz4：{sys.executable} 没装 lz4（nxsh_extract 的 Unity 扫描要它），第 4 项抽取断言未跑'); fail += 1; n += 1
else:
    ks = {l.split('\t')[0] for l in open(os.path.join(O, 'rows.tsv')) if not l.startswith('#')} if r.returncode == 0 else set()
    check(key(*C) in ks and key(*B) in ks and sum(1 for l in open(os.path.join(O, 'rows.tsv')) if f'@{H1:016x}#sdf|' in l) == 2 if ks else False,
          f'抽取：H1 只出新版两支（vs A + ps C），B 只来自 H2：真结果 rc={r.returncode}，H1 记录 {sum(1 for l in open(os.path.join(O, "rows.tsv")) if f"@{H1:016x}#sdf|" in l) if ks else "无"}')
    rows_h1 = [l.split('\t') for l in open(os.path.join(O, 'rows.tsv')) if f'@{H1:016x}#sdf|' in l] if ks else []
    check(sorted(x[0] for x in rows_h1) == sorted([key(*A), key(*C)]), f'H1 的两支 = 新版的 A、C（旧版 B 不在）：真结果 {sorted(x[0] for x in rows_h1)}')

# 5) 独立字面量 KPKA：头 16 字节、条目 48 字节、4 字节原样内容。
# 原长与存储长均为 4；尾部不是条目内容。期望不由 entries/read 生成。
literal = bytes.fromhex(
    '4b504b41 04000000 01000000 00000000'
    '11223344 55667788 4000000000000000'
    '0400000000000000 0400000000000000'
    '0000000000000000 0000000000000000'
    '007f80ff')
lp = os.path.join(T, 'literal.pak')
open(lp, 'wb').write(literal + b'outside-entry')
le = re_pak.entries(lp)
check(le == [(0x8877665544332211, 64, 4, 4, 0)], '字面量 stored 条目字段按格式读出')
with open(lp, 'rb') as f:
    check(re_pak.read(f, *le[0][1:]) == b'\x00\x7f\x80\xff', '合法 stored 返回原字节，不读条目后的尾部')

def rejects_literal(label, image, error=ValueError):
    open(lp, 'wb').write(image)
    entry = re_pak.entries(lp)[0]
    try:
        with open(lp, 'rb') as f: re_pak.read(f, *entry[1:])
    except error:
        check(True, label)
    else:
        check(False, label)

for declared in (5, 3, 0, -1):
    image = bytearray(literal)
    struct.pack_into('<q', image, 40, declared)  # 16 字节头 + 条目内 24：原长
    rejects_literal(f'stored 实际 4 字节、原长 {declared} 必须拒绝', image)
rejects_literal('stored 数据短 1 字节必须拒绝', literal[:-1])
rejects_literal('stored 数据起点即 EOF 必须拒绝', literal[:64])
empty = bytearray(literal[:64]); struct.pack_into('<qq', empty, 32, 0, 0)
open(lp, 'wb').write(empty)
with open(lp, 'rb') as f:
    check(re_pak.read(f, *re_pak.entries(lp)[0][1:]) == b'', '合法空 stored 条目仍返回空字节')
unknown = bytearray(literal); struct.pack_into('<q', unknown, 48, 7)
rejects_literal('未知压缩方式仍报 Unsupported', unknown, re_pak.Unsupported)
with open(e2[0], 'rb') as f:
    try: re_pak.read(f, e2[2], e2[3], e2[4] + 1, e2[5])
    except ValueError: check(True, 'deflate 原长不符仍拒绝')
    else: check(False, 'deflate 原长不符仍拒绝')

# 6) 真 consumer：坏条目不扫描，邻接合法条目保留记录与字节；不改全局退出策略。
one = shader(1, 99); broken_sdf = sdf([('RejectedStored', {0: 0})], [one])
mixed = os.path.join(T, 'mixed.pak')
kpka(mixed, [(H1, broken_sdf, 0), (H2, f1, 0)])
image = bytearray(open(mixed, 'rb').read()); struct.pack_into('<q', image, 40, len(broken_sdf) + 1)
open(mixed, 'wb').write(image)
entries, _ = re_pak.resolve([mixed]); mo = os.path.join(T, 'mixed-out'); os.makedirs(os.path.join(mo, 'src'))
mr, ms = X.work_kpka((entries, mo))
label = f'kpka:mixed.pak@{H2:016x}'
expected_rows = sorted((k, st, src.replace('t.sdf', label), v) for k, st, src, v in want)
check(sorted(mr) == expected_rows and ms['RE pak 条目解码失败'] == 1,
      f'真实 work_kpka 拒绝坏 stored、保留合法 5 条记录：真结果 {len(mr)} 条、解码失败 {ms["RE pak 条目解码失败"]}')
import srcpack
expected_files = {key(*sh): (sh[1], sh[0]) for sh in (A, B, C, Dc)}
sp = srcpack.Src(mo); actual_files = {k: sp.get(k) for k in sp.keys()}; sp.close()
check(actual_files == expected_files, '真实 work_kpka 只写合法 4 支（src/*.pk），机器码 / 控制段逐字节同夹具原文')
shutil.rmtree(T)
print(f'期望 RE 引擎程序表 {n} 项全过 → 真结果 失败 {fail} / {n}')
sys.exit(1 if fail else 0)
