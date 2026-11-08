#!/usr/bin/env python3
# 主程序内嵌着色器的程序表（10-21 画面·着色器线，巫师3 界面层 Scaleform 4.x 静态着色器管理器；布局从主程序字节推出，不认名字、不写死地址）：
#   主程序只读段里的着色器（抽取来源 nso:<模块>@adj<控制段偏移>，块 = [引擎头][控制段][机器码]）各有描述符，描述符里一个指针字段指向块起点（RELATIVE 重定位）；
#   全部描述符按阶段各进一个指针数组 Descs[]（下标 0 = 空槽 = 不用这个阶段），代码按「组合号 → (顶点下标 u32, 片元下标 u32)」表取一对描述符建程序。
#   本工具：① 由重定位找出每支着色器块的描述符和描述符起点（数组元素指向的地址）；② 找出两个数组（各自恰好装下一个阶段的全部描述符、前一槽为空）；
#   ③ 在非代码段里找组合表：最长的一段 u32 对，两列取值都不超过各自数组长度，两个数组的每个下标都出现过（覆盖全 = 是这张表，不是巧合的小整数），
#     且空项成对（一列为 0 另一列也为 0；错一个字读会出现半空项）；
#   ④ 表里每个非空对 = 一个程序。另加顶点专属变体（描述符 +8 Flags 位 2 = 实例化）：运行时实例化顶点会与同类型去掉批量 / 实例化位（Type 位 1、2）的基础顶点
#     在表里配的片元同用——依据：巫师3 Mac 局 Ryujinx 缓存里运行时现翻的 30 个界面程序，24 个是表里的对、6 个是实例化顶点 × 基础片元（10-21，gfxsh-extract）。
#   任一步对不上（没有重定位指向控制段 / 数组不唯一 / 表找不到或覆盖不全）就报「本款不适用」、不出表，不猜。
# 输出 TSV（S2A_PROG_TABLE 同格式）：vs键 \t hs键 \t ds键 \t gs键 \t ps键（缺的写 -）。用法：exe_shtab_programs.py <exefs/main> <rows.tsv> -o <输出 tsv>
import sys, os, re, struct, collections
import os as _os, sys as _sys; _sys.path.insert(0, _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), '../../../tools')); from nso_plain import plain as _nso_plain   # ZBIC（NSO 标志 0x80）先经 nx_unpack 规整成不压缩段，不各写一份解码（tools/nso_plain.py）
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import srcpack   # S2Arm 抽取的着色器字节（src/*.pk）
from array import array

R_AARCH64_RELATIVE = 1027


def load_nso(p):
    """(按内存偏移摆的镜像, [(拼接偏移, 内存偏移, 长度)]）：nxsh_extract.nso_image 是三段首尾拼接，抽取来源的偏移按拼接算"""
    import lz4.block
    raw = _nso_plain(open(p, 'rb').read(), p); segs = []
    for i, off in enumerate((0x10, 0x20, 0x30)):
        fo, mo, sz = struct.unpack_from('<III', raw, off); csz = struct.unpack_from('<I', raw, 0x60 + 4 * i)[0]
        segs.append((mo, lz4.block.decompress(raw[fo:fo + csz], uncompressed_size=sz) if (raw[0xc] >> i) & 1 else raw[fo:fo + csz]))
    bss = struct.unpack_from('<I', raw, 0x3c)[0]
    img = bytearray(max(m + len(d) for m, d in segs) + bss)
    for m, d in segs: img[m:m + len(d)] = d
    cat = []; p_ = 0
    for m, d in segs: cat.append((p_, m, len(d))); p_ += len(d)
    return bytes(img), cat


def relocs(img):
    """{目标地址: [写入位置…]}（只收 RELATIVE：数据段里的指针都是它）"""
    mod = struct.unpack_from('<I', img, 4)[0]
    if img[mod:mod + 4] != b'MOD0': raise ValueError('没有 MOD0')
    q = mod + struct.unpack_from('<i', img, mod + 4)[0]; D = {}
    while q + 16 <= len(img):
        t, v = struct.unpack_from('<qQ', img, q); q += 16
        if t == 0: break
        D.setdefault(t, v)
    if 7 not in D or 8 not in D: raise ValueError('动态段没有 RELA')
    inv = collections.defaultdict(list); slots = set()
    for o in range(D[7], D[7] + D[8], 24):
        off, info, add = struct.unpack_from('<QQq', img, o)
        if info & 0xffffffff == R_AARCH64_RELATIVE: inv[add].append(off); slots.add(off)
    return inv, slots


def find_tables(img, inv, slots, shaders, text_end):
    """shaders：{控制段地址: (键, 阶段)}。返回 ({阶段: [下标 → 键（0 = None）]}, {阶段: [下标 → 描述符地址]}, 组合表 [(a, b)], 列序（'vs','ps'）) 或抛 ValueError（说明不适用的原因）"""
    # 描述符里的指针指向着色器块起点：块 = [引擎自己的头][控制段][机器码]，头长度不定（巫师3 0x2d0）→ 取控制段前 0x1000 字节内最近的一个被指地址
    tg = sorted(inv); import bisect
    def blk(c):
        i = bisect.bisect_right(tg, c) - 1
        return tg[i] if i >= 0 and c - tg[i] < 0x1000 else None
    fields = {c: inv[blk(c)] if blk(c) is not None else [] for c in shaders}
    if not any(fields.values()): raise ValueError('没有指针指向内嵌着色器块')
    if not all(fields.values()): raise ValueError(f'{sum(1 for v in fields.values() if not v)} 支内嵌着色器块没有指针指向')
    # 描述符起点 = 字段位置 − d，d 取「全部字段都有数组元素指向 字段 − d」的那个
    allf = [(f, c) for c, fs in fields.items() for f in fs]
    ds = [d for d in range(0, 0x100, 8) if all(inv.get(f - d) for f, _ in allf)]
    if len(ds) != 1: raise ValueError(f'描述符起点认不出（候选字段偏移 {ds}）')
    d = ds[0]; desc = {f - d: shaders[c] for f, c in allf}
    # 数组：指向描述符起点的槽，按 8 字节连续成段
    sl = sorted((o, s) for s in desc for o in inv[s])
    runs = []; cur = []
    for o, s in sl:
        if cur and o != cur[-1][0] + 8: runs.append(cur); cur = []
        cur.append((o, s))
    if cur: runs.append(cur)
    arr = {}
    for st in sorted({v[1] for v in desc.values()}):
        need = {s for s, v in desc.items() if v[1] == st}
        cand = [r for r in runs if {s for _, s in r} == need and all(desc[s][1] == st for _, s in r)]
        if len(cand) != 1: raise ValueError(f'{st} 描述符数组不唯一（{len(cand)} 个候选）')
        r = cand[0]; z = r[0][0] - 8
        if z in slots or struct.unpack_from('<Q', img, z)[0] != 0: raise ValueError(f'{st} 描述符数组前一槽不是空槽（下标 0 = 不用）')
        arr[st] = [None] + [s for _, s in r]
    if set(arr) != {'vs', 'ps'}: raise ValueError(f'阶段不是顶点 + 片元两组：{sorted(arr)}')
    nv, nf = len(arr['vs']) - 1, len(arr['ps']) - 1
    # 组合表：非代码段里 u32 对，两列各不超过数组长度，覆盖全部下标
    best = []
    for order in (('vs', 'ps'), ('ps', 'vs')):
        na, nb = (nv, nf) if order[0] == 'vs' else (nf, nv)
        for al in (0, 4):
            lo = (text_end + 7 & ~7) + al; n = (len(img) - lo) // 8
            W = array('I'); W.frombytes(img[lo:lo + 8 * n])
            i = 0
            while i < n:
                if W[2 * i] <= na and W[2 * i + 1] <= nb and lo + 8 * i not in slots:
                    j = i
                    while j < n and W[2 * j] <= na and W[2 * j + 1] <= nb and lo + 8 * j not in slots: j += 1
                    if j - i >= max(na, nb):
                        A = set(W[2 * i:2 * j:2]); B = set(W[2 * i + 1:2 * j:2])
                        if A >= set(range(1, na + 1)) and B >= set(range(1, nb + 1)):
                            tab = [(W[2 * k], W[2 * k + 1]) for k in range(i, j)]
                            # 组合要么两阶段都有、要么都没有：一列为 0 另一列非 0 的项出现 = 列序 / 对齐错位（把上一项的片元当成这一项的顶点读）
                            if not any((x == 0) != (y == 0) for x, y in tab): best.append((j - i, lo + 8 * i, order, tab))
                    i = j
                else: i += 1
    if not best: raise ValueError('找不到覆盖全部描述符下标的组合表')
    best.sort(key=lambda x: -x[0])
    if len(best) > 1 and best[1][0] == best[0][0]: raise ValueError('组合表不唯一')
    _, at, order, tab = best[0]
    while tab and tab[0] == (0, 0): tab = tab[1:]; at += 8   # 首尾的全空项（相邻数据里的 0）不算表
    while tab and tab[-1] == (0, 0): tab = tab[:-1]
    if order != ('vs', 'ps'): tab = [(b, a) for a, b in tab]
    keys = {st: [None] + [desc[s][0] for s in arr[st][1:]] for st in arr}
    return keys, arr, tab, at


def programs(img, keys, arr, tab):
    """组合表的程序 + 实例化顶点 × 基础顶点在表里配的片元（键对集合，以及统计）"""
    P = {(a, b) for a, b in tab if a and b}
    fs_of = collections.defaultdict(set)
    for a, b in P: fs_of[a].add(b)
    def tf(i): t, _, fl = struct.unpack_from('<IIQ', img, arr['vs'][i]); return t, fl
    X = set()
    for a in fs_of:
        t, fl = tf(a)
        if not fl & 4: continue
        for u in fs_of:
            tu, fu = tf(u)
            if not fu & 4 and tu & ~6 == t & ~6: X |= {(a, b) for b in fs_of[u]}
    K = {(keys['vs'][a], keys['ps'][b]) for a, b in P | X}
    return K, len(P), len(X - P)


def main():
    a = sys.argv[1:]; out = None
    if '-o' in a: i = a.index('-o'); out = a[i + 1]; del a[i:i + 2]
    if len(a) != 2 or not out: print('用法：exe_shtab_programs.py <exefs/main> <rows.tsv> -o <输出 tsv>', file=sys.stderr); sys.exit(2)
    exe, rows_p = a; X = srcpack.Src(os.path.dirname(os.path.abspath(rows_p)))
    img, cat = load_nso(exe)
    def c2m(o):
        for p_, m, n in cat:
            if p_ <= o < p_ + n: return m + o - p_
    sh = {}; stat = collections.Counter()
    for l in open(rows_p, encoding='utf-8'):
        if l.startswith('#') or not l.strip(): continue
        k, st, src, _ = l.rstrip('\n').split('\t')
        m = re.match(r'^nso:[^@]*@adj0x([0-9a-f]+)$', src)
        if not m or st not in ('vs', 'ps'): continue
        c = c2m(int(m.group(1), 16)); ctl = X.get(k)[1]   # 相邻扫描的来源偏移 = 控制段起点（拼接偏移）
        if c is None or img[c:c + len(ctl)] != ctl: stat['控制段在镜像里对不上'] += 1; continue
        sh[c] = (k, st); stat['内嵌着色器'] += 1
    with open(out, 'w') as fo:
        fo.write('# vs键\ths键\tds键\tgs键\tps键\n')
        if not sh: print(f'主程序内嵌着色器程序表：本款不适用（没有内嵌的顶点 / 片元）{dict(stat)}', file=sys.stderr); return
        try:
            inv, slots = relocs(img)
            keys, arr, tab, at = find_tables(img, inv, slots, sh, cat[0][1] + cat[0][2])
        except ValueError as e:
            print(f'主程序内嵌着色器程序表：本款不适用（{e}）{dict(stat)}', file=sys.stderr); return
        K, nt, nx = programs(img, keys, arr, tab)
        for v, p in sorted(K): fo.write(f'{v}\t-\t-\t-\t{p}\n')
    print(f'主程序内嵌着色器程序表：{dict(stat)}；描述符 顶点 {len(arr["vs"]) - 1} / 片元 {len(arr["ps"]) - 1}，组合表 {len(tab)} 项 @{at:#x}，'
          f'表内程序 {nt} + 实例化顶点配基础片元 {nx}，按键去重 {len(K)}', file=sys.stderr)


if __name__ == '__main__':
    main()
