#!/usr/bin/env python3
# 特化评估统计（方案第九节③）：读 S2A_SPEC_LOG（Ryujinx ShaderCache 每建一个宿主程序一行），回答
#   ① 客体着色器数 vs 「客体 × 特化状态」组合数（= 宿主程序数）vs 不同 SPIR-V 数；
#   ② 每个特化字段的取值种数，以及逐个抹掉该字段后组合数降到多少（= 该字段贡献的放大）；
#   ③ 把「可改运行时参数」的字段一起抹掉后剩多少组合（出包期能静态全量编的下限）。
# 用法：spec_stats.py <S2A_SPEC_LOG 文件> [可运行时化字段,逗号分隔]
import sys, collections

path = sys.argv[1]
RUNTIME = (sys.argv[2].split(',') if len(sys.argv) > 2 else
           ['alpha_test', 'alpha_op', 'alpha_ref', 'psize', 'prog_psize', 'depth_mode', 'vp_disable', 'yneg', 'early_z', 'a2c_dither'])

rows = []
for ln in open(path, encoding='utf-8'):
    if ln.startswith('#') or not ln.strip(): continue
    f = ln.rstrip('\n').split('\t')
    kind, guest, spv = f[0], f[1], f[2]
    kv = {}
    for x in f[3:]:
        k, _, v = x.partition('='); kv[k] = v
    rows.append((kind, guest, spv, kv))

def combos(drop):
    s = set()
    for kind, guest, spv, kv in rows:
        s.add((kind, guest, tuple((k, v) for k, v in sorted(kv.items()) if k not in drop)))
    return len(s)

for kind in ('gfx', 'cs'):
    R = [r for r in rows if r[0] == kind]
    if not R: continue
    guests = {r[1] for r in R}
    # 单支客体着色器 → 它被翻成的不同 SPIR-V（同一客体代码在不同特化下的份数）。客体键按阶段位置排（下标 0 = 顶点 A / 计算），SPIR-V 按阶段名排，
    # 两者只能按「非空客体键」与「SPIR-V」的出现顺序对齐（ShaderCache 两者都按阶段升序）
    stage_guest = collections.defaultdict(set)
    for _, guest, spv, _ in R:
        gs = [g for g in guest.split(',') if g != '-']; ss = [x.partition(':')[2] for x in spv.split(',')]
        for g, k in zip(gs, ss): stage_guest[g].add(k)
    spvs = {s for r in R for s in r[2].split(',')}
    sd = collections.Counter(len(v) for v in stage_guest.values())
    print(f'== {"图形" if kind == "gfx" else "计算"}程序')
    print(f'  宿主程序（客体 × 特化）{len(R)} 个；客体程序（各阶段客体代码组合）{len(guests)} 个；放大 {len(R) / len(guests):.2f} 倍；不同 SPIR-V {len(spvs)} 支')
    per = collections.Counter(r[1] for r in R)
    dist = collections.Counter(per.values())
    print('  每个客体程序的特化份数分布：' + '，'.join(f'{k} 份 × {v}' for k, v in sorted(dist.items())))
    print(f'  单支客体着色器 {len(stage_guest)} 支 → 不同 SPIR-V 份数分布：' + '，'.join(f'{k} 份 × {v}' for k, v in sorted(sd.items())))

base = combos(set())
fields = sorted({k for r in rows for k in r[3]})
print(f'\n== 逐字段（全部组合 {base}）：取值种数 / 抹掉该字段后组合数')
res = []
for k in fields:
    vals = {r[3].get(k) for r in rows}
    res.append((base - combos({k}), k, len(vals)))
for gain, k, nv in sorted(res, reverse=True):
    print(f'  {k:12s} 取值 {nv:4d} 种  抹掉后 {base - gain:5d}（降 {gain}）')
rt = [k for k in RUNTIME if k in fields]
print(f'\n== 可运行时化字段一起抹掉（{",".join(rt)}）：{base} → {combos(set(rt))}；客体程序 {len({(r[0], r[1]) for r in rows})} 个')
