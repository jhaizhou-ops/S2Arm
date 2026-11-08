#!/usr/bin/env python3
# REDengine 3（巫师3）静态着色器程序配对：staticshadernx.cache 条目键 = FNV-1a64( fx名\0 + 宏表(名\0 值\0)… + 阶段 u32 )，
#   宏表 = [阶段宏（VERTEXSHADER / PIXELSHADER …）=1, __GLSL__=1, ST_OPENGL=1, __VERSION__=450] + 对象自己的宏（主程序 0xee9950 / 0x1032810 反汇编，10-21 pair）。
# 对象的（fx 名, 宏）静态读自主程序：每处把 *.fx 名串装进寄存器的代码起，到下一处 *.fx 之前，按出现顺序收集装进 x1 的字符串（宏名 / 值成对），
#   对连续的宏子段逐个算 VS（阶段 0）/ PS（阶段 1）两个键，两个键都在缓存里 = 一个程序（同一 CRenderShaderPair 的 VS + PS）。
# 曲面细分（hs / ds）条目键推不出，按 SPH 接口接到已配出的 vs + ps 上（tess_programs，10-21 gfxsh-extract）。
# 用法：red_static_programs.py <exefs/main> <rows.tsv> <romfs 根> -o <输出 tsv>
import sys, os, re, struct, collections
import os as _os, sys as _sys; _sys.path.insert(0, _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), '../../../tools')); from nso_plain import plain as _nso_plain   # ZBIC（NSO 标志 0x80）先经 nx_unpack 规整成不压缩段，不各写一份解码（tools/nso_plain.py）
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import nxsh_extract as X
# 仓库里唯一的 RomFS 遍历（graphics/nvn/tools/romfs_list.py：walk 同 os.walk）
sys.path.insert(0, os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'nvn', 'tools'))); import romfs_list
import srcpack   # S2Arm 抽取的着色器字节（src/*.pk）
G = [('__GLSL__', '1'), ('ST_OPENGL', '1'), ('__VERSION__', '450')]
def fnv(bs, h=0xcbf29ce484222325):
    for c in bs: h = ((h ^ c) * 0x100000001b3) & 0xffffffffffffffff
    return h
def key_hash(fx, defs, stage):
    sd = [('VERTEXSHADER', '1')] if stage == 0 else [('PIXELSHADER', '1')]
    return fnv(fx.encode() + b'\0' + b''.join(k.encode() + b'\0' + v.encode() + b'\0' for k, v in sd + G + defs) + struct.pack('<I', stage))
def nso_image(p):
    import lz4.block
    raw = _nso_plain(open(p, 'rb').read(), p); segs = []
    for i, off in enumerate((0x10, 0x20, 0x30)):
        fo, mo, sz = struct.unpack_from('<III', raw, off); csz = struct.unpack_from('<I', raw, 0x60 + 4 * i)[0]
        segs.append((mo, lz4.block.decompress(raw[fo:fo + csz], uncompressed_size=sz) if (raw[0xc] >> i) & 1 else raw[fo:fo + csz]))
    buf = bytearray(max(m + len(d) for m, d in segs))
    for m, d in segs: buf[m:m + len(d)] = d
    return bytes(buf), segs[0][0] + len(segs[0][1])
def cache_entries(paths):
    """{条目键哈希: 抽取键}"""
    out = {}
    for path in paths:
        d = open(path, 'rb').read(); i = 0; parts = []
        while True:
            j = d.find(b'\x28\xb5\x2f\xfd', i)
            if j < 0: break
            fr = X.zstd_frame(d, j)
            if not fr: i = j + 4; continue
            parts.append(fr[0]); i = j + fr[1]
        s = b''.join(parts); p = 0
        while p + 20 <= len(s) - 28:
            h, h2, L = struct.unpack_from('<QQI', s, p); rows = []
            X._scan_blob('e', s[p + 20:p + 20 + L], rows, {}, collections.Counter())
            if rows: out[h] = rows[0][0]
            p += 20 + L
    return out
def windows(img, te):
    """[(fx 名, [x1 依次装的串…])]：从装 *.fx 串起，到下一处 *.fx 串前"""
    W = struct.unpack_from(f'<{te // 4}I', img, 0)
    def cstr(a):
        if not 0 <= a < len(img): return None
        e = img.find(b'\0', a, a + 256); s = img[a:e]
        return s.decode('latin-1') if s and all(32 <= c < 127 for c in s) else ('' if e == a else None)
    regs = {}; cur = None; out = []
    for i, w in enumerate(W):
        if w & 0x9f000000 == 0x90000000:
            imm = (((w >> 5) & 0x7ffff) << 2) | ((w >> 29) & 3); imm -= (1 << 21) if imm & (1 << 20) else 0
            regs[w & 31] = (i * 4 & ~0xfff) + (imm << 12); continue
        if w & 0xffc00000 == 0x91000000 and (w >> 5) & 31 in regs:
            v = regs[(w >> 5) & 31] + ((w >> 10) & 0xfff); regs[w & 31] = v
            s = cstr(v)
            if s and s.endswith('.fx') and (w & 31) == 1:
                if cur: out.append(cur)
                cur = (s, [])
            continue
        if w & 0xffe0ffe0 == 0xaa0003e0:   # mov xd, xm
            m = (w >> 16) & 31
            if m in regs: regs[w & 31] = regs[m]
            else: regs.pop(w & 31, None)
            continue
        if w >> 26 == 0b100101 and cur is not None and 1 in regs:   # bl：此刻 x1 是串就记一个
            s = cstr(regs[1])
            if s and not s.endswith('.fx'): cur[1].append(s)   # 空串不收（AddDefine 等调用时 x1 是栈上对象、恰好读成空串）
            for r in range(19): regs.pop(r, None)
        if w == 0xd65f03c0 and cur: out.append(cur); cur = None
    if cur: out.append(cur)
    return out
def tess_programs(rows_p, progs, st, code_of=None):
    """静态缓存里的曲面细分（hs / ds）：条目键不按 vs / ps 的配方可推（10-21 巫师3 globalOcean.fx 的 hs / ds 试过 115 个 .fx 名 × 阶段宏 × 阶段号 × 全局宏子集 × 单个附加宏都对不上），
    按接口配：ds 读 ⊆ hs 写 的 hs；hs 读 = vs 写（逐分量相等）的 vs；片元取这支 vs 在静态程序里配的、读 ⊆ ds 写 的 ps。
    依据：巫师3 Mac 局唯一的曲面程序（vs a645 + hs 497b + ds 0ee5 + ps f068，globalOcean.fx）按此规则唯一配出。返回 {(vs, hs, ds, '-', ps)}"""
    code_of = code_of or srcpack.Src(os.path.dirname(os.path.abspath(rows_p))).get_code
    S = {}
    for l in open(rows_p, encoding='utf-8'):
        if l.startswith('#') or not l.strip(): continue
        k, stg, src, _ = l.rstrip('\n').split('\t')
        if 'staticshadernx.cache' in src and stg in ('vs', 'hs', 'ds', 'ps') and k not in S: S[k] = (stg, X.sph(code_of(k)))
    ps_of = collections.defaultdict(set)
    for v, p in progs: ps_of[v].add(p)
    out = set()
    for d, (sd, (di, do)) in S.items():
        if sd != 'ds': continue
        for h, (sh_, (hi, ho)) in S.items():
            if sh_ != 'hs' or di & ~ho: continue
            for v, (sv, (vi, vo)) in S.items():
                if sv != 'vs' or vo != hi: continue
                for p in ps_of.get(v, ()):
                    if not S.get(p, ('', (1 << 200, 0)))[1][0] & ~do: out.add((v, h, d, '-', p))
    st['曲面程序'] = len(out)
    return out
def static_caches(root):
    """RomFS 任意深度的 staticshadernx.cache（原先 glob('<根>/**/staticshadernx.cache', recursive=True)：同样跳过 . 开头的目录、名字逐字比对）"""
    for dp, dn, fn in romfs_list.walk(root):
        dn[:] = [d for d in dn if not d.startswith('.')]
        for f in dn + fn:
            if f == 'staticshadernx.cache': yield os.path.join(dp, f)
def main():
    a = sys.argv[1:]; out = a[a.index('-o') + 1]; del a[a.index('-o'):a.index('-o') + 2]
    exe, rows_p, root = a
    caches = sorted(static_caches(root))
    H = cache_entries(caches); img, te = nso_image(exe)
    progs = set(); vs_only = set(); st = collections.Counter()
    for fx, toks in windows(img, te):
        st['.fx 窗口'] += 1; got = set()
        for off in (0, 1):   # 宏名 / 值成对：从第 0 或第 1 个串起配对
            pairs = list(zip(toks[off::2], toks[off + 1::2]))
            for i in range(len(pairs) + 1):
                for j in range(i, len(pairs) + 1):
                    d = pairs[i:j]; hv, hp = key_hash(fx, d, 0), key_hash(fx, d, 1)
                    if hv in H and hp in H: got.add((H[hv], H[hp]))
        if got: st['配上的窗口'] += 1
        progs |= got
    vs_only = {v for v, p in progs}
    tess = tess_programs(rows_p, progs, st)
    with open(out, 'w') as fo:
        fo.write('# vs键\ths键\tds键\tgs键\tps键\n')
        for v, p in sorted(progs): fo.write(f'{v}\t-\t-\t-\t{p}\n')
        for v in sorted(vs_only): fo.write(f'{v}\t-\t-\t-\t-\n')
        for t in sorted(tess): fo.write('\t'.join(t) + '\n')
    print(f'REDengine 静态程序：{dict(st)}；缓存条目 {len(H)}；程序 {len(progs)} + 只顶点 {len(vs_only)} + 曲面 {len(tess)}', file=sys.stderr)
if __name__ == '__main__': main()
