#!/usr/bin/env python3
# 管线首用表按客体代码重定位（画面·着色器线 10-23）：首用表的函数名 = 翻译后 SPIR-V 的键，翻译器一改键就全变，旧行在新包里对不上
#   （动森 8ebc5d029 包：首用表 347 组、对上 0；预取热片 0、提前热 0）。客体代码指纹不随翻译器变：
#   键 → (阶段, 客体指纹) 的对照每次烘焙从 programs.tsv 追加进 <收集目录>/<款>/keymap.tsv；出包时首用表里本包没有的组合，
#   各阶段键经对照换成客体指纹、再在本包 programs.tsv 里找同一组指纹的程序，函数名换成本包的键、管线键编码里的程序哈希（前 8 字节）按运行时同一算法重算。
# 用法：
#   psoremap.py keymap <programs.tsv> <keymap.tsv>            把本次烘焙的 键→阶段/指纹 并进对照（只增不减）
#   psoremap.py resolve <pso_use.tsv> <keymap.tsv> <programs.tsv> <输出 pso_use.tsv>
# 程序哈希（graphics/metal/gal_prog.m prog_finish_hash）：SHA-256(6 个 u64 小端：各阶段 stage_hash，下标 cs0 vs1 tcs2 tes3 gs4 fs5) 的前 8 字节（小端 u64）；
#   stage_hash = 函数名里的 16 位十六进制。管线键编码第 0–7 字节就是它（gal_state.m pso_key.prog_hash，首个字段）；本脚本对每行先用旧名字重算、与编码里的比，
#   不等的行不改写（布局变了宁可丢，不给错键）。
import hashlib, os, struct, sys

ST = {'cs': 0, 'vs': 1, 'tcs': 2, 'tes': 3, 'gs': 4, 'fs': 5}


def prog_hash(stage_keys):
    arr = [0] * 6
    for st, k in stage_keys: arr[ST[st]] = k
    return hashlib.sha256(struct.pack('<6Q', *arr)).digest()[:8]


def dec(s):
    b = bytearray(); i = 0
    while i < len(s):
        if s[i] == '-': b += bytes(int(s[i + 1:i + 3], 16)); i += 3
        else: b.append(int(s[i:i + 2], 16)); i += 2
    return bytes(b)


def enc(b):
    out = []; i = 0
    while i < len(b):
        n = 0
        while i + n < len(b) and b[i + n] == 0 and n < 255: n += 1
        if n >= 2: out.append('-%02x' % n); i += n
        else: out.append('%02x' % b[i]); i += 1
    return ''.join(out)


def programs(path):
    """本包程序：[(阶段列表, 键列表, 指纹列表)]（只要写进缓存的 ok 行）"""
    res = []
    for ln in open(path, encoding='utf-8'):
        c = ln.rstrip('\n').split('\t')
        if len(c) < 7 or not c[0].isdigit() or not c[6]: continue
        sts = [t.split(':') for t in c[5].split()]
        keys = c[6].split(',')
        if len(sts) != len(keys) or any(len(s) < 4 or s[0] not in ST for s in sts): continue
        res.append(([s[0] for s in sts], keys, [s[3] for s in sts]))
    return res


def cmd_keymap(prog, km):
    have = set()
    try:
        for ln in open(km, encoding='utf-8'):
            if not ln.startswith('#'): have.add(ln.rstrip('\n'))
    except FileNotFoundError: pass
    new = []
    for sts, keys, fps in programs(prog):
        for st, k, fp in zip(sts, keys, fps):
            row = f'{k}\t{st}\t{fp}'
            if row not in have: have.add(row); new.append(row)
    hdr = not have - set(new)
    # 谁写谁建（10-23 用户体验线 Air 新机：收集目录还没有，追加写直接 FileNotFoundError、出包红）。位置随 S2A_SHCOLLECT：开发机 run/s2arm/shcollect，玩家机由前端设到自己的缓存目录（pack/jobs/core.py）
    os.makedirs(os.path.dirname(os.path.abspath(km)), exist_ok=True)
    with open(km, 'a', encoding='utf-8') as f:
        if hdr: f.write('# 键→客体指纹对照（psoremap.py keymap，每次烘焙追加）：<SPIR-V 键>\t<阶段>\t<客体代码指纹>\n')
        for r in new: f.write(r + '\n')
    print(f'键对照：本次 {len(new)} 条新增，合计 {len(have)} 条')


def cmd_resolve(use, km, prog, out):
    k2 = {}
    for ln in open(km, encoding='utf-8'):
        if ln.startswith('#'): continue
        k, st, fp = ln.rstrip('\n').split('\t')
        k2.setdefault(k, set()).add((st, fp))
    cur = programs(prog)
    have = {','.join(keys) for _, keys, _ in cur}
    byfp = {}
    for sts, keys, fps in cur: byfp.setdefault(tuple(zip(sts, fps)), []).append((sts, keys))
    n = {'本包有': 0, '重定位': 0, '重定位出行': 0, '对照里没有': 0, '本包无同指纹程序': 0, '程序哈希核不上': 0}
    rows, seen = [], set()
    for ln in open(use, encoding='utf-8'):
        if ln.startswith('#'): continue
        c = ln.rstrip('\n').split('\t')
        if len(c) < 4: continue
        names = [x[1:17] for x in c[2].split(',')]
        if ','.join(names) in have:
            n['本包有'] += 1; rows.append(c); continue
        cand = [k2.get(x) for x in names]
        if any(not s for s in cand): n['对照里没有'] += 1; continue
        keyb = dec(c[3])
        # 每个旧键可能对应不止一个（阶段, 指纹）——同一份 SPIR-V 在不同程序里当同一阶段用，指纹相同；取各键唯一的那个，多于一个按组合逐一试
        combos = [[]]
        for s in cand: combos = [p + [x] for p in combos for x in sorted(s)]
        hit = []
        for cb in combos:
            sts = [st for st, _ in cb]
            if prog_hash(list(zip(sts, (int(x, 16) for x in names)))) != keyb[:8]: continue
            hit += byfp.get(tuple(cb), [])
        if not hit:
            if not any(prog_hash(list(zip([st for st, _ in cb], (int(x, 16) for x in names)))) == keyb[:8] for cb in combos): n['程序哈希核不上'] += 1
            else: n['本包无同指纹程序'] += 1
            continue
        n['重定位'] += 1
        for sts, keys in hit:
            nk = prog_hash(list(zip(sts, (int(x, 16) for x in keys)))) + keyb[8:]
            rows.append([c[0], c[1], ','.join('s' + x for x in keys), enc(nk)])
            n['重定位出行'] += 1
    with open(out, 'w', encoding='utf-8') as f:
        f.write('# 管线首用表（psouse.py 收、psoremap.py 按客体指纹重定位到本包）：<首用帧>\t<b|f>\t<函数名串>\t<管线键编码>，按首用帧升序\n')
        for c in sorted(rows, key=lambda c: int(c[0])):
            t = (c[1], c[3])
            if t in seen: continue
            seen.add(t); f.write('\t'.join(c[:4]) + '\n')
    print('首用表重定位：' + '，'.join(f'{k} {v}' for k, v in n.items()) + f'；写出 {len(seen)} 行')


if __name__ == '__main__':
    a = sys.argv[1:]
    if a[:1] == ['keymap'] and len(a) == 3: cmd_keymap(*a[1:])
    elif a[:1] == ['resolve'] and len(a) == 5: cmd_resolve(*a[1:])
    else: print('用法：psoremap.py keymap <programs.tsv> <keymap.tsv> | resolve <pso_use.tsv> <keymap.tsv> <programs.tsv> <输出>', file=sys.stderr); sys.exit(2)
