#!/usr/bin/env python3
# 程序配对的静态推导（创新方案一，10-20 首个落点暗黑2）：从游戏主程序推「vs 文件 × ps 文件」配对，出包时 shader_pack.sh 在抽取到 SHAD 包时自动调用。
# 每个抽到的着色器文件 <阶段>_<名>.bin 在主程序里的名字串 = <名>（如 models_v、alpha_threshold_p、atmosphere_apply）；
# 找名字串的全部代码引用（ADRP + ADD）；同一处构造程序的代码会紧挨着引用 vs 名和 ps 名：相距 ≤ W 字节的一个 vs 文件引用 + 一个 ps 文件引用 = 一对。
# 输出 <输出 tsv>：vs 文件名 \t ps 文件名 \t 引用点；并报对数、涉及文件数。用法：exe_pairs.py <主程序镜像> <rows.tsv> <输出 tsv> [窗口字节，缺省 128]
# 读数（暗黑2，10-20）：83 对，旧局缓存 34 份去重 85 个图形程序全部覆盖（shbake --ref-cover）
import sys, struct, re, collections
import os as _os, sys as _sys; _sys.path.insert(0, _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), '../../../tools')); from nso_plain import plain as _nso_plain   # ZBIC（NSO 标志 0x80）先经 nx_unpack 规整成不压缩段，不各写一份解码（tools/nso_plain.py）
img_path, rows_path, out_path = sys.argv[1:4]; W = int(sys.argv[4]) if len(sys.argv) > 4 else 128
img = open(img_path, 'rb').read()
if img[:4] == b'NSO0':   # 原始 exefs/main：三段（代码 / 只读 / 数据）按各自内存偏移摆进 0 基址镜像（ADRP 按页相对寻址，段间距必须是真的）
    import lz4.block
    raw, segs = _nso_plain(img, img_path), []
    for i, off in enumerate((0x10, 0x20, 0x30)):
        fo, mo, sz = struct.unpack_from('<III', raw, off); csz = struct.unpack_from('<I', raw, 0x60 + 4 * i)[0]
        segs.append((mo, lz4.block.decompress(raw[fo:fo + csz], uncompressed_size=sz) if (raw[0xc] >> i) & 1 else raw[fo:fo + csz]))
    buf = bytearray(max(mo + len(d) for mo, d in segs))
    for mo, d in segs: buf[mo:mo + len(d)] = d
    img = bytes(buf)
files = collections.defaultdict(set)   # 名字串 → {(阶段, 文件名)}
for l in open(rows_path).read().split('\n')[1:]:
    if not l or l.startswith('#'): continue
    k, st, src, v = l.split('\t')
    f = src.split('@')[0].split('/')[-1]
    m = re.match(r'(vs|ps|hs|ds|gs|cs)_(.*)\.bin$', f)
    if m and m.group(1) in ('vs', 'ps'): files[m.group(2)].add((m.group(1), f))
addr = {}
for n in files:
    b = n.encode() + b'\0'
    for m in re.finditer(re.escape(b), img):
        if m.start() == 0 or img[m.start() - 1] == 0: addr[m.start()] = n
words = struct.unpack_from(f'<{len(img) // 4}I', img, 0)
page = {}; refs = []   # (pc, 名字串)
for i, w in enumerate(words):
    pc = i * 4
    if w & 0x9f000000 == 0x90000000:
        rd = w & 31; imm = (((w >> 5) & 0x7ffff) << 2) | ((w >> 29) & 3); imm -= (1 << 21) if imm & (1 << 20) else 0
        page[rd] = ((pc & ~0xfff) + (imm << 12), pc)
    elif w & 0xffc00000 == 0x91000000:
        rn = (w >> 5) & 31
        if rn in page and pc - page[rn][1] < 64:
            t = page[rn][0] + ((w >> 10) & 0xfff)
            if t in addr: refs.append((pc, addr[t]))
refs.sort()
pairs = {}
for i, (pc, n) in enumerate(refs):
    for st, f in files[n]:
        if st != 'ps': continue
        for pc2, n2 in refs:   # 窗口内的 vs 引用（前后都看）
            if abs(pc2 - pc) > W: continue
            for st2, f2 in files[n2]:
                if st2 == 'vs': pairs.setdefault((f2, f), pc)
seen_names = {n for _, n in refs}
print(f'名字串 {len(files)} 个，在主程序里找到 {len(set(addr.values()))} 个、有代码引用的 {len(seen_names)} 个；引用 {len(refs)} 处；窗口 {W} 字节内配出 {len(pairs)} 对')
nf = {f for n in files for _, f in files[n]}
used = {x for p in pairs for x in p}
print(f'涉及文件 {len(used)} / {len(nf)}；没进任何配对的 vs / ps 文件：', sorted(nf - used)[:30])
with open(out_path, 'w') as o:
    for (v, p), pc in sorted(pairs.items()): o.write(f'{v}\t{p}\t{pc:#x}\n')
