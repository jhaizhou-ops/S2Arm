#!/usr/bin/env python3
# REDengine 3（巫师3 Switch 版）shadernx.cache 程序配对：按缓存自身的材质条目表把各阶段着色器组成程序（10-21 曲面细分线调研，格式从文件字节推出）。
# 用法：rdhs_programs.py <rows.tsv> <romfs 根> [-o 输出.tsv] [--stat] [--tess-only] [--vs-only]
# 输出 TSV：vs键 \t hs键 \t ds键 \t gs键 \t ps键（缺的阶段写 -），每行一个程序（按键去重）；shader_pack.sh 交给 shbake（S2A_PROG_TABLE）。
# --tess-only：只出带 hs / ds 的程序（10-21 曲面线只接曲面时用；10-21 pair 起出包取全量：巫师3 9 局真值 231 个图形程序里 96 个只在这张表里）
# --vs-only：每个条目的 vs 另出一个只有顶点的程序（只深度的通道不绑片元：巫师3 真值 4 个只顶点程序的 vs 都是表里条目的 vs，条目表本身没有只顶点的条目）
#
# shadernx.cache 布局（从文件字节推出，9 个文件逐字节解析到尾部完全吻合）：
#   [着色器区] 从 0 起连续 n_sh 条：u64 着色器哈希 | u8 压缩标志(=1) | u32 解压长 | u32 压缩长 | zstd 帧(压缩长)
#   [条目区]   从 info_off 起连续 n_ent 条（每条 = 一个材质的一个技术变体 = 一个程序）：
#       u32 条目号 | u32 材质路径哈希 | u64 条目哈希 | u64 烘焙时间戳(全文件同值) | 串「路径.w2mg [条目号] 」
#       u32 条目号(重复) | u64 槽[6]：0=vs 1=ps 2=gs 3=hs 4=ds 5=(未用，推定 cs)，0 = 该阶段不存在
#       u32 0 | u32 nS | nS×32 字节(采样器状态) | u32 nV + nV×(串, u8) | u32 nP + nP×(串, u8)
#   [尾 48 字节] u32 n_sh | u32 n_ent | u64 0 | u64 info_off | u64 info_size | u64 info_off | "RDHS" | u32 3
#   串 = CR2W 变长串：首字节 bit7=ASCII、bit6=还有一字节、低 6 位为长度低位；续字节 ×64。
# 槽里的哈希只引用同一文件着色器区里的着色器（9 个文件实测无跨文件引用）。
# staticshadernx.cache（FZLC 分块 zstd，解开后是 u64 哈希 | u64 哈希2 | u32 长 | 程序体 的连续序列 + 28 字节尾）
# 没有任何程序表，其中的 vs/ps/gs/hs/ds/cs 由引擎代码在运行时按名字现配，本脚本不输出（见 --stat 的计数）。
import sys, os, struct, collections

SLOT_STAGE = ('vs', 'ps', 'gs', 'hs', 'ds', 'cs')


def rstr(d, p):
    b = d[p]; n = b & 0x3f; p += 1
    if b & 0x40: n += d[p] << 6; p += 1
    return d[p:p + n], p + n


def parse_cache(d):
    """返回 ({帧偏移: 着色器哈希}, [(条目号, 路径, 槽[6])])；结构不符直接抛错。"""
    if len(d) < 48 or d[-8:-4] != b'RDHS': raise ValueError('尾部不是 RDHS')
    ns, ne, z, io, isz, io2 = struct.unpack_from('<IIQQQQ', d, len(d) - 48)
    if z != 0 or io2 != io or io + isz + 48 != len(d): raise ValueError('尾部字段不自洽')
    frames = {}; p = 0
    for _ in range(ns):
        h = d[p:p + 8]; ul, cl = struct.unpack_from('<II', d, p + 9)
        if d[p + 17:p + 21] != b'\x28\xb5\x2f\xfd': raise ValueError(f'{p:#x} 不是 zstd 帧')
        frames[p + 17] = h; p += 17 + cl
    if p != io: raise ValueError(f'着色器区止于 {p:#x}，尾部记 {io:#x}')
    ents = []
    for _ in range(ne):
        id1, = struct.unpack_from('<I', d, p); name, e = rstr(d, p + 24)
        id2, = struct.unpack_from('<I', d, e)
        if id1 != id2: raise ValueError(f'{p:#x} 条目号前后不一致')
        slots = [d[e + 4 + 8 * j:e + 12 + 8 * j] for j in range(6)]
        r = e + 52; a, nS = struct.unpack_from('<II', d, r); r += 8 + 32 * nS
        for _ in range(2):
            nP, = struct.unpack_from('<I', d, r); r += 4
            for _ in range(nP): _, r = rstr(d, r); r += 1
        ents.append((id1, name.decode('latin-1').rstrip(), slots)); p = r
    if p != len(d) - 48: raise ValueError(f'条目区止于 {p:#x}，应到 {len(d) - 48:#x}')
    return frames, ents


def main():
    a = sys.argv[1:]; out = None; stat = '--stat' in a; tess_only = '--tess-only' in a; vs_only = '--vs-only' in a
    if stat: a.remove('--stat')
    if tess_only: a.remove('--tess-only')
    if vs_only: a.remove('--vs-only')
    if '-o' in a: i = a.index('-o'); out = a[i + 1]; del a[i:i + 2]
    if len(a) != 2: print('用法：rdhs_programs.py <rows.tsv> <romfs 根> [-o 输出.tsv] [--stat] [--tess-only] [--vs-only]', file=sys.stderr); sys.exit(2)
    rows_p, root = a
    R = collections.defaultdict(lambda: collections.defaultdict(set))   # 文件 -> 帧偏移 -> {(键, 阶段)}
    allkeys = collections.defaultdict(set)                              # 阶段 -> 键（全部来源）
    for l in open(rows_p, encoding='utf-8'):
        if l.startswith('#') or not l.strip(): continue
        k, st, src, _v = l.rstrip('\n').split('\t')
        allkeys[st].add(k)
        f = src.split('@', 1)[0]
        if f.endswith('shadernx.cache') and not f.endswith('staticshadernx.cache') and '@zs' in src:
            zs = int(src.split('@zs', 1)[1].split('@', 1)[0], 16); R[f][zs].add((k, st))
    progs = set(); cnt = collections.Counter()
    for f in sorted(R):
        d = open(os.path.join(root, f), 'rb').read()
        frames, ents = parse_cache(d)
        h2k = collections.defaultdict(set)
        for zs, ks in R[f].items():
            if zs not in frames: raise ValueError(f'{f}@{zs:#x} 不是着色器区帧起点')
            h2k[frames[zs]] |= ks
        cnt['文件'] += 1; cnt['条目'] += len(ents)
        for _id, _name, slots in ents:
            per = {}
            for j, h in enumerate(slots):
                if h == bytes(8): continue
                ks = {k for k, st in h2k.get(h, ()) if st == SLOT_STAGE[j]}
                if not ks: cnt[f'槽{j}({SLOT_STAGE[j]}) 引用无对应行'] += 1; per = None; break
                per[SLOT_STAGE[j]] = sorted(ks)
            if per is None: continue
            if 'cs' in per: cnt['槽5 非零（未预期）'] += 1
            combos = [()]
            for st in ('vs', 'hs', 'ds', 'gs', 'ps'):
                combos = [c + (k,) for c in combos for k in per.get(st, ['-'])]
            progs.update(combos)
    if vs_only: progs |= {(p[0], '-', '-', '-', '-') for p in progs if p[0] != '-'}
    progs = sorted(p for p in progs if not tess_only or p[1] != '-' or p[2] != '-')
    fo = open(out, 'w') if out else sys.stdout
    fo.write('# vs键\ths键\tds键\tgs键\tps键\n')
    for p in progs: fo.write('\t'.join(p) + '\n')
    if out: fo.close()
    if stat:
        cov = {st: {p[i] for p in progs} - {'-'} for i, st in enumerate(('vs', 'hs', 'ds', 'gs', 'ps'))}
        print(f'文件 {cnt["文件"]}，条目 {cnt["条目"]}，去重程序 {len(progs)}', file=sys.stderr)
        for st in ('vs', 'hs', 'ds', 'gs', 'ps'):
            print(f'  {st}: 进程序 {len(cov[st])} / rows 全部 {len(allkeys[st])}', file=sys.stderr)
        for k, v in sorted(cnt.items()):
            if k not in ('文件', '条目'): print(f'  {k}: {v}', file=sys.stderr)


if __name__ == '__main__':
    main()
