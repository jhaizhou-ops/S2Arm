#!/usr/bin/env python3
# 程序配对 + 宏取值的静态推导（创新方案一；10-20 首个落点暗黑2，零游戏配置）：从游戏主程序读出「代码实际会建的程序」。
# ① 自动认函数：构造程序 = 调用时 x1、x4 都指向已抽到的着色器文件名串的 bl 目标；注册宏 = 调用时 x1 指向 SHAD 排列宏名串的 bl 目标（w0 = 编号）。
# ② 每个构造调用点往回到上一条 ret（≤ 600 条），线性符号执行：立即数、ADRP 地址、只读数据加载、栈写入（含 sp 派生寄存器），
#    读出 vs / ps 两份宏数组（每项 0x18 字节：编号 u32 @0、取值下标 u32 @0x10，个数 w3 / w6）。
#    取值是变量时取「窗口里赋给那个寄存器的全部立即数」（超集，安全）；读不出的记 *（按 SHAD 表全取值展开）。
# 输出 tsv：vs 文件 \t ps 文件 \t vs 宏（名=下标|下标…，逗号分隔） \t ps 宏 \t 调用点。用法：exe_programs.py <exefs/main> <rows.tsv> <输出 tsv>
import sys, struct, re, collections, lz4.block, capstone
import os as _os, sys as _sys; _sys.path.insert(0, _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), '../../../tools')); from nso_plain import plain as _nso_plain   # ZBIC（NSO 标志 0x80）先经 nx_unpack 规整成不压缩段，不各写一份解码（tools/nso_plain.py）
from capstone import arm64_const as A
exe, rows_path, out_path = sys.argv[1:4]
raw = _nso_plain(open(exe, 'rb').read(), exe); segs = []
for i, off in enumerate((0x10, 0x20, 0x30)):
    fo, mo, sz = struct.unpack_from('<III', raw, off); csz = struct.unpack_from('<I', raw, 0x60 + 4 * i)[0]
    segs.append((mo, lz4.block.decompress(raw[fo:fo + csz], uncompressed_size=sz) if (raw[0xc] >> i) & 1 else raw[fo:fo + csz]))
img = bytearray(max(m + len(d) for m, d in segs))
for m, d in segs: img[m:m + len(d)] = d
img = bytes(img); text_end = segs[0][0] + len(segs[0][1]); W = struct.unpack_from(f'<{text_end // 4}I', img, 0)

# 抽取结果：着色器文件名（名字串 = 去掉阶段前缀与 .bin）与 SHAD 宏名
names, defnames = {}, set()
for l in open(rows_path).read().split('\n')[1:]:
    if not l or l.startswith('#'): continue
    src = l.split('\t')[2]; f = src.split('@')[0].split('/')[-1]
    m = re.match(r'(vs|ps)_(.*)\.bin$', f)
    if m: names[m.group(2)] = f if m.group(1) == 'vs' else names.get(m.group(2) + '#vs', f)
    if m: names.setdefault((m.group(1), m.group(2)), f)
    if '|' in src:
        for kv in src.split('|', 1)[1].split(','):
            if '=' in kv: defnames.add(kv.split('=')[0])
def cstr(a):
    if not (0 <= a < len(img)): return None
    e = img.find(b'\0', a, a + 128)
    if e < 0: return None
    s = img[a:e]
    return s.decode() if 1 <= len(s) and all(32 <= c < 127 for c in s) else None
md = capstone.Cs(capstone.CS_ARCH_ARM64, capstone.CS_MODE_ARM); md.detail = True

def window_start(pc):
    k = pc // 4 - 1
    while k > pc // 4 - 600 and W[k] != 0xd65f03c0: k -= 1   # ret
    return (k + 1) * 4

R = lambda r: {**{getattr(A, f'ARM64_REG_X{i}'): i for i in range(31)}, **{getattr(A, f'ARM64_REG_W{i}'): i for i in range(31)}}.get(r)
XREGS = {getattr(A, f'ARM64_REG_X{i}') for i in range(31)} | {A.ARM64_REG_XZR}
CAP = 16
def join(a, b):   # 值：('i', 立即数集合) / ('a', 地址) / ('s', 栈偏移) / None（未知）；汇合 = 立即数求并集，其余相同才保留
    if a == b: return a
    if a and b and a[0] == 'i' and b[0] == 'i':
        u = a[1] | b[1]; return ('i', u) if len(u) <= CAP else None
    return None
def jstate(x, y):
    r = {k: join(x[0].get(k), y[0].get(k)) for k in set(x[0]) | set(y[0])}
    s = {k: join(x[1].get(k), y[1].get(k)) for k in set(x[1]) | set(y[1])}
    return ({k: v for k, v in r.items() if v}, {k: v for k, v in s.items() if v})
def step(ins, st):
    reg, stk = dict(st[0]), dict(st[1]); m, ops = ins.mnemonic, ins.operands
    def rv(o):
        if o.type == A.ARM64_OP_IMM: return ('i', {o.imm})
        if o.type == A.ARM64_OP_REG:
            if o.reg in (A.ARM64_REG_XZR, A.ARM64_REG_WZR): return ('i', {0})
            if o.reg == A.ARM64_REG_SP: return ('s', 0)
            return reg.get(R(o.reg))
        return None
    def setr(o, v):
        r = R(o.reg)
        if r is None: return
        if v: reg[r] = v
        else: reg.pop(r, None)
    if m in ('mov', 'movz') and len(ops) == 2: setr(ops[0], rv(ops[1]))
    elif m == 'adrp': setr(ops[0], ('a', ops[1].imm))
    elif m == 'add' and len(ops) == 3 and ops[2].type == A.ARM64_OP_IMM:
        b = rv(ops[1]); sh = ops[2].shift.value if ops[2].shift.type else 0
        if b and b[0] in ('a', 's'): setr(ops[0], (b[0], b[1] + (ops[2].imm << sh)))
        elif b and b[0] == 'i': setr(ops[0], ('i', {x + (ops[2].imm << sh) for x in b[1]}))   # 循环计数等：集合加法，汇合超上限即未知（安全）
        else: setr(ops[0], None)
    elif m in ('ldr', 'ldur', 'ldp', 'ldrb', 'ldrh') and ops[-1].type == A.ARM64_OP_MEM:
        mo = ops[-1].mem; b = ('s', 0) if mo.base == A.ARM64_REG_SP else reg.get(R(mo.base))
        for j in range(2 if m == 'ldp' else 1):
            o = ops[j]; wid = 1 if m == 'ldrb' else 2 if m == 'ldrh' else 8 if o.reg in XREGS else 4
            if b and b[0] == 'a':
                a = b[1] + mo.disp + j * wid; setr(o, ('i', {int.from_bytes(img[a:a + wid], 'little')}) if 0 <= a < len(img) - wid else None)
            elif b and b[0] == 's': setr(o, stk.get(b[1] + mo.disp + j * wid) if wid == 4 else (stk.get(b[1] + mo.disp + j * wid) if (b[1] + mo.disp + j * wid + 4) not in stk else
                 (lambda lo, hi: ('i', {next(iter(lo[1])) | next(iter(hi[1])) << 32}) if lo and hi and lo[0] == hi[0] == 'i' and len(lo[1]) == len(hi[1]) == 1 else lo)(stk.get(b[1] + mo.disp + j * wid), stk.get(b[1] + mo.disp + j * wid + 4))))
            else: setr(o, None)
    elif m in ('str', 'stur', 'stp', 'strb', 'strh') and ops[-1].type == A.ARM64_OP_MEM:
        mo = ops[-1].mem; b = ('s', 0) if mo.base == A.ARM64_REG_SP else reg.get(R(mo.base))
        if b and b[0] == 's':
            for j in range(2 if m == 'stp' else 1):
                o = ops[j]; wid = 1 if m == 'strb' else 2 if m == 'strh' else 8 if o.reg in XREGS else 4
                v = rv(o); off = b[1] + mo.disp + j * wid
                if wid == 8:   # 按 4 字节两半存（宏数组按 4 字节读编号 / 取值）
                    if v and v[0] == 'i': stk[off] = ('i', {x & 0xffffffff for x in v[1]}); stk[off + 4] = ('i', {x >> 32 for x in v[1]})
                    else: stk[off] = v; stk.pop(off + 4, None)
                else: stk[off] = v
                stk = {k: x for k, x in stk.items() if x}
    elif m == 'bl' or ins.group(A.ARM64_GRP_CALL):
        for r in range(19): reg.pop(r, None)
    elif ops and ops[0].type == A.ARM64_OP_REG and m not in ('cmp', 'cmn', 'tst', 'ccmp') and not (m.startswith('b') and len(m) <= 4) and m not in ('cbz', 'cbnz', 'tbz', 'tbnz'):
        setr(ops[0], None)
    return reg, stk
def simulate_lin(pc):
    """同窗口顺序执行（不看分支、不合并）：调用点前最后一次赋值支配调用，补 CFG 汇合后变未知的寄存器 / 栈槽"""
    s0 = window_start(pc); st = ({}, {})
    for x in md.disasm(img[s0:pc], s0): st = step(x, st)
    return st
CAPHIT = 0
def simulate(pc):
    """寄存器 = CFG 结果，没有的用顺序执行补（名串指针 / 数组基址 / 个数是调用前紧挨着赋值的）；栈另给两份：宏取值只认 CFG（CFG 未知 = 不约束），
    编号允许顺序执行补。10-20 反例：ui_p 在 7 次循环里按循环变量建 UI_DRAW_MODE 0..6，顺序执行只看到 0"""
    c = simulate_cfg(pc); l = simulate_lin(pc)
    return ({**l[0], **c[0]}, (c[1], {**l[1], **c[1]}))
def simulate_cfg(pc):
    """调用点 pc 时刻的抽象状态（寄存器、栈）：窗口 = 上一条 ret 之后到 pc，按分支建图、汇合求并、迭代到不动点"""
    s0 = window_start(pc); e = pc // 4 + 1
    while e < pc // 4 + 2000 and e < len(W) and W[e] != 0xd65f03c0: e += 1   # 窗口含调用点之后到函数末尾：循环回边常在调用之后（ui_p 的 7 次循环）
    ins = list(md.disasm(img[s0:e * 4 + 4], s0)); idx = {x.address: k for k, x in enumerate(ins)}; cp = idx[pc]
    succ = []
    for k, x in enumerate(ins):
        m = x.mnemonic; nx = [k + 1] if k + 1 < len(ins) else []
        tgt = None
        if m in ('b', 'cbz', 'cbnz', 'tbz', 'tbnz') or m.startswith('b.'):
            o = x.operands[-1]
            if o.type == A.ARM64_OP_IMM: tgt = idx.get(o.imm)
        if m == 'b': nx = [tgt] if tgt is not None else []
        elif tgt is not None: nx = nx + [tgt]
        if m in ('ret', 'br'): nx = []
        succ.append(nx)
    st = {0: ({}, {})}; work = [0]; it = 0
    while work and it < 400000:
        it += 1; k = work.pop()
        out = step(ins[k], st[k])
        for n in succ[k]:
            if n is None: continue
            if n not in st: st[n] = out; work.append(n)
            else:
                j = jstate(st[n], out)
                if j != st[n]: st[n] = j; work.append(n)
    global CAPHIT
    if work: CAPHIT += 1   # 没到不动点就停了（计数报出来，不静默）
    return st.get(cp, ({}, {}))

# ① 认函数
cand = collections.Counter(); regc = collections.Counter(); calls = collections.defaultdict(list)
fname_set = {k[1] for k in names if isinstance(k, tuple)}
def regstr(reg, r):
    v = reg.get(r); return cstr(v[1]) if v and v[0] == 'a' else None
# 只在引用了着色器名串的函数里找（先扫名串 ADRP+ADD 引用点，取其后 200 条内的 bl），否则全程序符号执行太慢
page = {}; near = set()
want = set()
for n in fname_set | defnames:
    for mm in re.finditer(re.escape(n.encode() + b'\0'), img):
        if img[mm.start() - 1] == 0: want.add(mm.start())
for i, w in enumerate(W):
    if w & 0x9f000000 == 0x90000000:
        imm = (((w >> 5) & 0x7ffff) << 2) | ((w >> 29) & 3); imm -= (1 << 21) if imm & (1 << 20) else 0; page[w & 31] = ((i * 4) & ~0xfff) + (imm << 12)
    elif w & 0xffc00000 == 0x91000000 and (w >> 5) & 31 in page and page[(w >> 5) & 31] + ((w >> 10) & 0xfff) in want:
        for k in range(i, min(i + 200, len(W))):
            if W[k] >> 26 == 0b100101: near.add(k * 4)
for pc in sorted(near):
    w = W[pc // 4]; t = pc + (((w & 0x3ffffff) ^ 0x2000000) - 0x2000000) * 4
    reg, stk = simulate(pc)
    a1, a4 = regstr(reg, 1), regstr(reg, 4)
    if a1 in fname_set and a4 in fname_set: cand[t] += 1; calls[t].append((pc, reg, stk))
CREATE = cand.most_common(1)[0][0] if cand else None
if CREATE is None:   # 零配置：找不到入口不硬配，明确报不适用（10-20：动森走档案自带程序表，暗黑3 / 巫师3 的着色器不按文件名串在代码里引用）
    print('本款不适用：主程序里没有「调用时同时传 vs 与 ps 文件名串」的构造入口，退回同主干全展开 / 容器自带程序表')
    open(out_path, 'w').close(); sys.exit(0)
print(f'构造程序函数 {CREATE and hex(CREATE)}（{cand[CREATE] if CREATE else 0} 处）；候选 {[(hex(t), c) for t, c in cand.most_common(3)]}')
idname = {}   # 编号 → 宏名：宏名串的 ADRP+ADD 引用点之后最近的 bl（注册函数），取调用点 w0 的立即数（宏名可能先拷进栈上字符串对象，x1 不直接指向它）
page = {}
for i, w in enumerate(W):
    if w & 0x9f000000 == 0x90000000:
        imm = (((w >> 5) & 0x7ffff) << 2) | ((w >> 29) & 3); imm -= (1 << 21) if imm & (1 << 20) else 0; page[w & 31] = ((i * 4) & ~0xfff) + (imm << 12)
    elif w & 0xffc00000 == 0x91000000 and (w >> 5) & 31 in page:
        nm = cstr(page[(w >> 5) & 31] + ((w >> 10) & 0xfff))
        if nm in defnames:
            for k in range(i + 1, min(i + 40, len(W))):
                if W[k] >> 26 == 0b100101:
                    v = simulate(k * 4)[0].get(0)
                    if v and v[0] == 'i' and len(v[1]) == 1: idname.setdefault(next(iter(v[1])), nm)
                    break
print(f'宏编号表 {len(idname)} 个')
def defs(stk, base, cnt):
    if not (base and base[0] == 's' and cnt and cnt[0] == 'i' and len(cnt[1]) == 1): return None
    cfg, mix = stk; out = []
    for e in range(next(iter(cnt[1]))):
        o = base[1] + 0x18 * e; i = mix.get(o); v = cfg.get(o + 0x10)
        nm = idname.get(next(iter(i[1]))) if i and i[0] == 'i' and len(i[1]) == 1 else None
        out.append(f'{nm or "?"}={"|".join(map(str, sorted(v[1]))) if v and v[0] == "i" else "*"}')
    return ','.join(out)
n_ok = n_bad = 0
with open(out_path, 'w') as o:
    for pc, reg, stk in calls[CREATE]:
        vs, ps = regstr(reg, 1), regstr(reg, 4)
        vf, pf = names.get(('vs', vs)), names.get(('ps', ps))
        dv, dp = defs(stk, reg.get(2), reg.get(3)), defs(stk, reg.get(5), reg.get(6))
        if dv is None or dp is None: n_bad += 1
        else: n_ok += 1
        o.write(f'{vf}\t{pf}\t{dv if dv is not None else "*"}\t{dp if dp is not None else "*"}\t{pc:#x}\n')
print(f'抽象解释未到不动点 {CAPHIT} 次')
print(f'构造调用 {n_ok + n_bad} 处：宏数组读出 {n_ok}，读不出 {n_bad}（记 *，按全取值展开）→ {out_path}')
