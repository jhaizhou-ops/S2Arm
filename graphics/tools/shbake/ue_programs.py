#!/usr/bin/env python3
# UE4（4.25+ 冷冻着色器表）程序配对（10-21 pair，八方旅人2 = UE 4.27）：材质 .uexp / 全局 GlobalShaderCache-*.bin 里的冷冻 FShaderMapContent →
#   每支着色器的（类型名、频率、代码下标）→ 抽取键，按 UE4 的类型对应关系配 vs × ps，输出 S2A_PROG_TABLE（vs \t hs \t ds \t gs \t ps，缺的写 -）。
# 冷冻布局（10-21 对着八方2 定，最小样本 DebugMeshMaterial 8 支全部对上；全量 43922 支频率与抽取阶段一致、不一致 72）：
#   - 冷冻指针 = (相对自身地址的偏移 << 1) | 1（有符号，可指回前面——同一材质的第二张 VF 表与第一张共用类型数组）；数组头 = 指针 u64 + 个数 u32 + 容量 u32。
#   - FShaderMapContent：类型名数组（FHashedName u64）、排列号数组（i32）、着色器指针数组、管线数组 四个数组头相邻；+0x48 = FMeshMaterialShaderMap 的 VF 名。
#   - FShader：+0xC0 Target（低 3 位 = 频率 0 vs / 3 ps / 5 cs，其上 = 平台），+0xC4 代码下标（本材质 FShaderMapResourceCode 里第几支代码，按出现顺序）。
#   - FHashedName = CityHash64WithSeed(大写 ANSI 名, FName 编号)（主程序 FHashedName(const FName&) 的反汇编：转大写后调 CityHash64WithSeed，种子 = FName.Number）。
#     名字表取主程序里的 UTF-16 / ASCII 串（类型注册名都在：TBasePassVSFNoLightMapPolicy 等）。
# 配对规则（依据：八方2 4 局 Mac 真值 106 个图形程序全部命中）：
#   - 材质表（每张 VF 表 / 材质表各自）：类型名去掉前缀 T/F 后按「VS」/「PS」切成 族 + 余部；同族 VS × PS 配；BasePass 族还要光照策略一致
#     （VS 余部去掉 AtmosphericFog、PS 余部去掉 Skylight 后相同）。每支材质 VS 另出只顶点程序（深度 / 阴影通道不绑片元）。
#   - 全局表：同族 VS × PS；通用顶点（没有同族 PS 的孤 VS、名字含 Screen 的全屏 VS）× 全部全局 PS。
#   - 全局几何（<族>GS）：同族 VS + GS × 同族 PS，没有同族 PS 时 × 读 ⊆ GS 写 的全局 PS（global_gs，10-21 gfxsh-extract）。
# 用法：ue_programs.py <rows.tsv> <romfs 根> <exefs/main> -o <输出 tsv>；标准错误打统计
import sys, os, re, struct, collections
import os as _os, sys as _sys; _sys.path.insert(0, _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), '../../../tools')); from nso_plain import plain as _nso_plain   # ZBIC（NSO 标志 0x80）先经 nx_unpack 规整成不压缩段，不各写一份解码（tools/nso_plain.py）
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
# 仓库里唯一的 RomFS 遍历（graphics/nvn/tools/romfs_list.py：walk 同 os.walk，listdir 同 os.listdir）
sys.path.insert(0, os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'nvn', 'tools'))); import romfs_list
import unreal_pak as ue_pak, cityhash, nxsh_extract as X
import srcpack   # S2Arm 抽取的着色器字节（src/*.pk）
FREQ = {0: 'vs', 1: 'hs', 2: 'ds', 3: 'ps', 4: 'gs', 5: 'cs'}
def nso_image(p):   # 按内存偏移摆段（ADRP / 串地址要真实），不是 nxsh_extract.nso_image 的首尾相接
    import lz4.block
    raw = _nso_plain(open(p, 'rb').read(), p); segs = []
    for i, off in enumerate((0x10, 0x20, 0x30)):
        fo, mo, sz = struct.unpack_from('<III', raw, off); csz = struct.unpack_from('<I', raw, 0x60 + 4 * i)[0]
        segs.append((mo, lz4.block.decompress(raw[fo:fo + csz], uncompressed_size=sz) if (raw[0xc] >> i) & 1 else raw[fo:fo + csz]))
    buf = bytearray(max(m + len(d) for m, d in segs))
    for m, d in segs: buf[m:m + len(d)] = d
    return bytes(buf)
def name_table(img):
    names = {m.group(1).decode('utf-16-le') for m in re.finditer(rb'((?:[A-Za-z0-9_<>,:]\x00){3,120})\x00\x00', img)}
    names |= {m.group(1).decode() for m in re.finditer(rb'(?<=\0)([A-Za-z_][A-Za-z0-9_<>,:]{2,120})\0', img)}
    return {cityhash.city64_seed(n.upper().encode(), 0): n for n in names}
def _arr(d, o):
    p, n, m = struct.unpack_from('<qII', d, o); t = o + (p >> 1)
    return (t, n) if p & 1 and n == m and 0 < n < 5000 and 0 <= t < len(d) else (None, 0)
_ODD = re.escape(bytes(range(1, 256, 2)))
_HDR = re.compile(b'(?=[' + _ODD + b'][\\x00-\\xff]{2}(?:\\x00{5}|\\xff{5})([\\x00-\\xff]{2})\\x00\\x00\\1\\x00\\x00)')
def tables(d):
    """[(表偏移, VF 名哈希, [(类型名哈希, 频率, 平台, 代码下标)])]"""
    out = []
    for mm in _HDR.finditer(d):
        o = mm.start()
        if o + 0x50 > len(d): continue
        t, n = _arr(d, o)
        if not t: continue
        _, n2 = _arr(d, o + 16); sh, n3 = _arr(d, o + 32)
        if n2 != n or n3 != n or t + 8 * n > len(d) or sh + 8 * n > len(d): continue
        rec = []
        for i in range(n):
            q = struct.unpack_from('<q', d, sh + 8 * i)[0]; so = sh + 8 * i + (q >> 1)
            if not q & 1 or not 0 <= so <= len(d) - 0xc8: rec = None; break
            tg, ri = struct.unpack_from('<Ii', d, so + 0xc0)
            rec.append((struct.unpack_from('<Q', d, t + 8 * i)[0], tg & 7, tg >> 3, ri))
        if rec and len({r[2] for r in rec}) == 1: out.append((o, struct.unpack_from('<Q', d, o + 0x48)[0], rec))
    return out
def family(n):
    m = re.match(r'^[TF]?(.*?)(VS|PS)(.*)$', n)
    if not m: return None, None
    a, c = m.group(1), m.group(3)
    if a == 'BasePass': c = re.sub(r'(AtmosphericFog|Skylight)$', '', c)
    else: c = ''
    return m.group(2), (a, c)
def pair_file(d, entries, H, is_global, stat):
    """entries：本文件 {条目偏移: (键, 阶段)}；返回 (vs×ps 集, 只顶点 vs 集, 全局用 [(类型名, 阶段, 键)])"""
    E = sorted(entries); P = set(); V = set(); G = []
    for o, vf, rec in tables(d):
        after = [e for e in E if e > o]; vs = collections.defaultdict(set); ps = collections.defaultdict(set)
        stat['表'] += 1
        for th, fq, pl, ri in rec:
            if not 0 <= ri < len(after): stat['代码下标越界'] += 1; continue
            k, st = entries[after[ri]]
            if FREQ.get(fq) != st: stat['频率与抽取阶段不一致（丢）'] += 1; continue
            tn = H.get(th); stat['着色器'] += 1
            if tn is None: stat['类型名认不出'] += 1; continue
            if is_global: G.append((tn, st, k)); continue
            kind, fam = family(tn)
            if kind == 'VS' and st == 'vs': vs[fam].add(k); V.add(k)
            elif kind == 'PS' and st == 'ps': ps[fam].add(k)
        for f, vv in vs.items():
            for v in vv:
                for p in ps.get(f, ()): P.add((v, p))
    return P, V, G
def global_pairs(G):
    vs = collections.defaultdict(set); ps = collections.defaultdict(set); screen = set(); allps = set()
    for tn, st, k in G:
        kind, fam = family(tn)
        if st == 'vs':
            vs[fam if kind == 'VS' else None].add(k)
            if 'Screen' in tn: screen.add(k)
        elif st == 'ps': ps[fam if kind == 'PS' else None].add(k); allps.add(k)
    P = {(v, p) for f in vs if f is not None and f in ps for v in vs[f] for p in ps[f]}
    generic = set().union(*[v for f, v in vs.items() if f is None or f not in ps]) | screen
    P |= {(v, p) for v in generic for p in allps}
    return P, len(generic), len(allps)
def global_gs(G, sph_of):
    """全局表里的几何着色器（类型名 <族>GS）：同族 VS（写 ⊇ GS 读）+ GS + 片元。片元 = 同族 PS；没有同族 PS 的（WriteToSlice 这类通用 GS，供体积贴图逐层画）
    取读 ⊆ GS 写 的全部全局 PS（与通用顶点 × 全部全局 PS 同一思路）。依据：八方2 Mac 局唯一的几何程序 FWriteToSliceVS + FWriteToSliceGS 配了
    TOneColorPixelShaderMRT 与 LUT 混合 PS 两支（10-21，gfxsh-extract），都在此规则内。返回 ({(vs, gs, ps)}, 统计)"""
    vs = collections.defaultdict(set); ps = collections.defaultdict(set); allps = set(); gs = []; st = collections.Counter()
    for tn, s_, k in G:
        if s_ == 'gs':
            m = re.match(r'^[TF]?(.*?)GS(.*)$', tn)
            if m: gs.append(((m.group(1), ''), k))
            else: st['几何类型名认不出'] += 1
            continue
        kind, fam = family(tn)
        if s_ == 'vs' and kind == 'VS': vs[fam].add(k)
        elif s_ == 'ps':
            allps.add(k)
            if kind == 'PS': ps[fam].add(k)
    out = set()
    for fam, g in gs:
        gi, go = sph_of(g)
        V = {v for v in vs.get(fam, ()) if not gi & ~sph_of(v)[1]}
        if not V: st['几何没有同族顶点'] += 1; continue
        P = ps[fam] if fam in ps else {p for p in allps if not sph_of(p)[0] & ~go}
        out |= {(v, g, p) for v in V for p in P}; st['几何程序族'] += 1
    return out, st
def main():
    a = sys.argv[1:]; out = None
    if '-o' in a: i = a.index('-o'); out = a[i + 1]; del a[i:i + 2]
    if len(a) != 3 or not out: print('用法：ue_programs.py <rows.tsv> <romfs 根> <exefs/main> -o <输出 tsv>', file=sys.stderr); sys.exit(2)
    rows_p, root, exe = a
    ent = collections.defaultdict(dict)
    for l in open(rows_p, encoding='utf-8'):
        if l.startswith('#') or not l.strip(): continue
        k, st, src, _ = l.rstrip('\n').split('\t')
        m = re.match(r'^pak:(.*)@ue0x([0-9a-f]+)\+', src)
        if m: ent[m.group(1)][int(m.group(2), 16)] = (k, st)
    stat = collections.Counter(); P = set(); V = set(); G = []; GP = set()
    if ent:
        H = name_table(nso_image(exe)); stat['名字哈希'] = len(H)
        paks = sorted(os.path.join(dp, f) for dp, dn, fn in romfs_list.walk(root) for f in fn if f.lower().endswith('.pak') and ue_pak.is_pak(os.path.join(dp, f)))
        for pp in paks:
            pk = ue_pak.Pak(pp)
            for name, eo in pk.files:
                if name not in ent: continue
                try: d = pk.read(eo)
                except Exception: stat['pak 条目读失败'] += 1; continue
                stat['文件'] += 1
                p, v, g = pair_file(d, ent[name], H, 'GlobalShaderCache' in name, stat); P |= p; V |= v; G += g
        gp, ng, nps = global_pairs(G); stat['全局通用顶点'] = ng; stat['全局 PS'] = nps; stat['全局程序'] = len(gp); stat['材质程序'] = len(P); P |= gp
        SRC = srcpack.Src(os.path.dirname(os.path.abspath(rows_p))); SC = {}
        def sph_of(k):
            if k not in SC: SC[k] = X.sph(SRC.get(k)[0])
            return SC[k]
        GP, gst = global_gs(G, sph_of); stat.update(gst); stat['全局几何程序'] = len(GP)
    with open(out, 'w') as fo:
        fo.write('# vs键\ths键\tds键\tgs键\tps键\n')
        for v, p in sorted(P): fo.write(f'{v}\t-\t-\t-\t{p}\n')
        for v in sorted(V): fo.write(f'{v}\t-\t-\t-\t-\n')
        for v, g, p in sorted(GP): fo.write(f'{v}\t-\t-\t{g}\t{p}\n')
    print(f'UE 冷冻着色器表：{dict(stat)}；程序 {len(P)} + 只顶点 {len(V)} + 几何 {len(GP)}', file=sys.stderr)
if __name__ == '__main__': main()
