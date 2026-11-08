#!/usr/bin/env python3
# 管线分片「内容定义分块」单测（graphics/tools/shbake/pso_gen.py）：增删一个程序只动 1–2 片的键。约 1 秒，不要 Metal 工具链。退出 0 = 全过
# 做法：假 metallib（只有函数表：NAME s<键> + HASH）+ 只有计算程序的程序表，平均片长 P = 30（→ CDC_N 17、CDC_MIN 10、CDC_MAX 60），跑真 pso_gen.py。
#   名字按位置造：第 i 个计算函数键 = (i+1)·2^40 + t（t < 2^40，保持键序 = 位置序），t 从 0 往上找到「是 / 不是候选」（sha256(s<键>) 前 8 字节小端 mod 17 == 0）为止。
#   基准 200 个，候选放在位置 19 25 49 79 85 140 199（其余都不是候选）。按规则手算（候选离上一个候选 ≥ 10 才切；开头算 -1；超过 60 均分）：
#     19（距 -1 为 20）切；25（距 19 为 6）不切；49（24）切；79（30）切；85（6）不切；140（55）切；199（59）切
#     → 自然片 [0,19] [20,49] [50,79] [80,140] [141,199]，长 20 / 30 / 30 / 61 / 59；61 > 60 均分成 30 + 31 → 期望片长 20 30 30 30 31 59（6 片）
#   变体与期望「新出现的片键数」（= 要重编的片；其余片键必须原样在）：
#     ① 删位置 60（非候选，在 [50,79]）                                          → 1（只这一片）
#     ② 在位置 2、3 之间插一个非候选                                             → 1（第一片）
#     ③ 在 [0,19] 里位置 9 之后插一个候选（离 -1 为 11、离它到 19 为 10 → 两个都切）→ 2（第一片劈成 11 + 10）
#     ④ 删候选 49（[20,49] [50,79] 并成一片，长 59，不超上限）                    → 1
#     ⑤ 删位置 100（非候选，在超长自然片 [80,140] 里）：长 60 不再超 → 1 片      → 1
#     ⑥ 删位置 27（非候选）：候选 49 离上一候选 25 的距离 24 → 23 照切；只动 [20,49] → 1
#     ⑦ 删位置 20、21、22（非候选；候选 25 离 19 的距离 6 → 3，照样不切）            → 1（只动 [20,49]）
#     ⑧ 程序表打乱顺序（固定种子）、集合不变                                      → 0（片与键全同：分块只看集合，不看表序）
#   程序表除 ⑧ 外按名字升序写。反证（PSO_GEN=<旧版 pso_gen.py> 跑本单测应红）：旧切法按表序每 P 个切 → 基准片长 30×6 + 20；
#     ① 删位置 60 → [60,90) 及其后全部错位，新键 5 片（期望 1）；② 插在开头 → 7 片全变；⑧ 打乱 → 7 片全变
import hashlib, json, os, struct, subprocess, sys, tempfile
H = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GEN = os.environ.get('PSO_GEN', os.path.join(H, 'pso_gen.py'))
P, N = 30, 17
def cand(name): return int.from_bytes(hashlib.sha256(name.encode()).digest()[:8], 'little') % N == 0
def mk(i, want, frac=0):   # 第 i 个位置的函数名（frac 让插入的名字排在 i 与 i+1 之间），want = 是否候选
    t = 0
    while True:
        k = (i + 1) * (1 << 40) + frac * (1 << 39) + t; nm = f's{k:016x}'
        if cand(nm) == want: return nm
        t += 1
CANDS = {19, 25, 49, 79, 85, 140, 199}
base = [mk(i, i in CANDS) for i in range(200)]
def metallib(path, names):   # 'MTLB' 头 0x58 字节（0x18 / 0x20 = 函数表偏移 / 长度，长度不含个数 u32）+ 函数表
    ents = b''
    for nm in names:
        tags = b'NAME' + struct.pack('<H', len(nm) + 1) + nm.encode() + b'\0' + b'HASH' + struct.pack('<H', 32) + hashlib.sha256(b'h' + nm.encode()).digest() + b'ENDT'
        ents += struct.pack('<I', 4 + len(tags)) + tags
    hd = bytearray(0x58); hd[:4] = b'MTLB'; struct.pack_into('<QQ', hd, 0x18, 0x58, len(ents))
    open(path, 'wb').write(bytes(hd) + struct.pack('<I', len(names)) + ents)
def run(tag, names, cold=None, order=None, use=None):
    d = os.path.join(T, tag); os.makedirs(d)
    env = {k: v for k, v in os.environ.items() if k not in ('S2A_PSO_USE', 'S2A_PSO_COLD_P')}
    env['S2A_PSO_COLD_P'] = str(cold if cold else P)   # 下面手算的分块都按 P 切（冷片片长默认 8 另测，见末尾「冷片缺省」项）
    if use is not None: open(os.path.join(d, 'pso_use.tsv'), 'w').write(use); env['S2A_PSO_USE'] = os.path.join(d, 'pso_use.tsv')
    metallib(os.path.join(d, 'gal.0.metallib'), names)
    open(os.path.join(d, 'gal.shards'), 'w').write('0000000000000000\tgal.0.metallib\n')
    hd = bytearray(24); hd[:4] = b'GALI'; open(os.path.join(d, 'gal.idx'), 'wb').write(bytes(hd))   # 0 条记录（只有计算程序，不查标志位）
    rows = ''.join(f'{i}\tt\tok\tcompute\tt\tt\t{nm[1:]}\t0\t\n' for i, nm in enumerate(order(names) if order else names))
    open(os.path.join(d, 'programs.tsv'), 'w').write('idx\torigin\tstatus\tkind\tsource\tstages\tspv\tms\terr\n' + rows)
    r = subprocess.run([sys.executable, GEN, os.path.join(d, 'programs.tsv'), os.path.join(d, 'gal.idx'), os.path.join(d, 'gal.shards'), os.path.join(d, 'pso'), str(P)], capture_output=True, text=True, env=env)
    if r.returncode: print(f'✗ {tag}：pso_gen 失败 {r.stderr[-300:]}'); return None
    n = json.loads(r.stdout.strip().splitlines()[-1])['chunks']; out = []
    for c in range(n):
        j = json.load(open(os.path.join(d, f'pso.{c}.mtl4-json'))); kf = os.path.join(d, f'pso.{c}.key')
        out.append((len(j['pipeline_descriptors']['compute_pipeline_descriptors']), open(kf).read() if os.path.exists(kf) else None))
    return out
T = tempfile.mkdtemp(prefix='t_pso_cdc.'); fail = 0; n = 0
def ck(ok, msg):
    global fail, n
    n += 1; print(('✓ ' if ok else '✗ ') + msg); fail += 0 if ok else 1
b = run('base', base)
if b is None: sys.exit(1)
ck(all(k for _, k in b), f'基准每片都出键（{sum(1 for _, k in b if k)}/{len(b)}）')
ck([c for c, _ in b] == [20, 30, 30, 30, 31, 59], f'基准片长 = 手算 20 30 30 30 31 59（实际 {" ".join(str(c) for c, _ in b)}）')
bk = {k for _, k in b}
# 「管线描述 → 归档片号」索引 pso.idx（运行时 graphics/metal/gal_core.m pso_arch_for 按它只开那一片）：条数 = 管线数，每条管线的键指向它实际所在的片；
#   键 = FNV-1a 64(函数名)（计算管线只有一个函数名），本单测按定义自己算，不调 pso_gen 的实现
def fnv(t):
    x = 0xcbf29ce484222325
    for c in t.encode(): x = ((x ^ c) * 0x100000001b3) % (1 << 64)
    return x
ixp = os.path.join(T, 'base', 'pso.idx'); ix = open(ixp, 'rb').read() if os.path.exists(ixp) else b'\0' * 16
ck(os.path.exists(ixp), 'pso_gen 写出归档索引 pso.idx'); mg, ver, cnt, _ = struct.unpack_from('<4I', ix, 0)
got = {struct.unpack_from('<Q', ix, 16 + 16 * i)[0]: struct.unpack_from('<I', ix, 24 + 16 * i)[0] for i in range(cnt)}
want = {}
for c in range(len(b)):
    j = json.load(open(os.path.join(T, 'base', f'pso.{c}.mtl4-json'))); nm = {f['label']: f['name'] for f in j['function_descriptors']['library_function_descriptors']}
    for d in j['pipeline_descriptors']['compute_pipeline_descriptors']: want[fnv(nm[d['compute_function_descriptor'][4:]])] = c
keys = [struct.unpack_from('<Q', ix, 16 + 16 * i)[0] for i in range(cnt)]
ck(mg == 0x49535047 and ver == 1 and len(ix) == 16 + 16 * cnt and keys == sorted(keys), f'归档索引头与长度对、键升序（{cnt} 条，{len(ix)} 字节）')
ck(cnt == 200 and got == want, f'归档索引 200 条、每条指向管线实际所在片（实得 {cnt} 条，不符 {sum(1 for k in want if got.get(k) != want[k])}）')
def var(tag, names, want, why, order=None):
    v = run(tag, names, order=order)
    if v is None: ck(False, tag); return
    new = sum(1 for _, k in v if k not in bk); gone = len(bk - {k for _, k in v})
    ck(new == want, f'{tag}：新出现的片键 {new}（期望 {want}：{why}）；消失 {gone}；片长 {" ".join(str(c) for c, _ in v)}')
var('① 删非候选 60', base[:60] + base[61:], 1, '只动 [50,79]')
var('② 开头插非候选', base[:3] + [mk(2, False, 1)] + base[3:], 1, '只动第一片')
var('③ 插候选劈开第一片', base[:10] + [mk(9, True, 1)] + base[10:], 2, '[0,19] 劈成 11 + 10')
var('④ 删候选 49', base[:49] + base[50:], 1, '[20,49] [50,79] 并成长 59 的一片')
var('⑤ 删超长片里的 100', base[:100] + base[101:], 1, '[80,140] 长 61 → 60，不再均分')
var('⑥ 删非候选 27', base[:27] + base[28:], 1, '只动 [20,49]')
var('⑦ 删 20 21 22', base[:20] + base[23:], 1, '只动 [20,49]')
import random
var('⑧ 程序表打乱顺序', base, 0, '集合不变', lambda x: random.Random(7).sample(x, len(x)))
# ⑨ 管线首用表（S2A_PSO_USE）：表里按行序出现 150、3、150（重复）、77 → 热区一片、按首次出现排 [150, 3, 77]，索引指片 0；
#   其余 197 个照内容定义分块，手算：抽走的都不是候选，候选间距 19：-1→19 20→19、79：49→79 30→29、199：140→199 59→58，都照切；
#   → 冷区片长 19 30 29 30 31 58（[0,19] 少 3、[50,79] 少 77、[141,199] 少 150；[80,140] 照旧均分 30 + 31），新片键 = 热区 1 + 冷区 3 = 4，[20,49] 与 [80,140] 两份原键不变
use = '# 管线首用表\n' + ''.join(f'{fr}\tb\t{base[i]}\t-ff\n' for fr, i in ((5, 150), (9, 3), (9, 150), (12, 77)))
v = run('⑨ 首用表', base, use=use)
if v is None: ck(False, '⑨ 首用表')
else:
    j0 = json.load(open(os.path.join(T, '⑨ 首用表', 'pso.0.mtl4-json'))); nm0 = {f['label']: f['name'] for f in j0['function_descriptors']['library_function_descriptors']}
    h0 = [nm0[x['compute_function_descriptor'][4:]] for x in j0['pipeline_descriptors']['compute_pipeline_descriptors']]
    ck(h0 == [base[150], base[3], base[77]], f'⑨ 热区第一片 = 表里首次出现序 150 3 77（实得位置 {[base.index(x) for x in h0]}）')
    ck([c for c, _ in v] == [3, 19, 30, 29, 30, 31, 58], f'⑨ 片长 = 手算 3 19 30 29 30 31 58（实得 {" ".join(str(c) for c, _ in v)}）')
    new = sum(1 for _, k in v if k not in bk); ck(new == 4, f'⑨ 新片键 {new}（期望 4：热区 1 + 冷区被抽走的 3 片）')
    ix9 = open(os.path.join(T, '⑨ 首用表', 'pso.idx'), 'rb').read(); c9 = struct.unpack_from('<I', ix9, 8)[0]
    g9 = {struct.unpack_from('<Q', ix9, 16 + 16 * i)[0]: struct.unpack_from('<I', ix9, 24 + 16 * i)[0] for i in range(c9)}
    ck(c9 == 200 and all(g9.get(fnv(base[i])) == 0 for i in (150, 3, 77)), f'⑨ 索引 200 条、表里三支指片 0（实得 {c9} 条，{[g9.get(fnv(base[i])) for i in (150, 3, 77)]}）')
# 冷片缺省（10-24 异度神剑3 低区）：不给 S2A_PSO_COLD_P 时冷片按 8 条切（CDC_N 4、CDC_MIN 2、CDC_MAX 16）——
#   期望（不变式，不复述实现）：每片 ≤ 16 条；片数比按 P = 30 切的基准（6 片）多
cd = run('冷片缺省 8', base, cold=8)
ck(cd is not None and max(x for x, _ in cd) <= 16 and len(cd) > len(b), f'冷片缺省 8：每片 ≤ 16、片数多于 P = 30 的 {len(b)} 片（实得 {len(cd) if cd else 0} 片、最长 {max(x for x, _ in cd) if cd else -1}）')
import shutil; shutil.rmtree(T, ignore_errors=True)
print(f'管线分片内容定义分块：{n} 项，失败 {fail}')
sys.exit(1 if fail else 0)
