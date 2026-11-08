#!/usr/bin/env python3
# 按「同一个文件」配程序（10-21 pair，巫师3 SpeedTree / 暗黑3 SNO 文件）：抽取 rows.tsv → 程序表（S2A_PROG_TABLE 同格式：vs \t hs \t ds \t gs \t ps，缺的写 -）。两条规则：
#  ① 同主干文件名：<目录>/<主干>_vs.<扩展>[_后缀] × <目录>/<主干>_ps.<扩展>[_后缀]（巫师3 bin/shaders/speedtree：branches_vs.glslobj[_nowind] × branches_ps.glslobj[_dissolve_free…]，
#     一个主干 = 一种几何 × 一种通道，后缀是风 / 溶解 / 不丢弃开关）。依据：巫师3 9 局 Mac 真值里 SpeedTree 程序 10 个全是同主干组合（不同主干的同字节着色器按键去重后自然覆盖）。
#  ② 同一压缩流 = 同一个资源文件：认不出外层打包格式、按 zlib 流解出再扫的来源（<文件>@z<流偏移>+<流内偏移>）同一流里的 vs × ps（暗黑3 cpk：一个流 = 一个 SNO 着色器文件，2–8 支）。
#     依据：暗黑3 9 局真值 100 个程序的 vs / ps 全部在同一流里。一个流里 vs 或 ps 超过 MAXN 支不配（笛卡尔积会炸，计数报出）。
# 用法：file_pairs.py <rows.tsv> <输出 tsv>；标准错误打一行统计
import sys, re, collections, itertools
MAXN = 16
rows, out = sys.argv[1:3]
stem = collections.defaultdict(lambda: collections.defaultdict(set)); stream = collections.defaultdict(lambda: collections.defaultdict(set))
for l in open(rows, encoding='utf-8'):
    if l.startswith('#') or not l.strip(): continue
    k, st, src, _ = l.rstrip('\n').split('\t')
    if st not in ('vs', 'ps'): continue
    f = src.split('@', 1)[0]
    m = re.match(r'^(.*/)?([^/]+)_(vs|ps)\.([A-Za-z0-9]+)(_\w+)?$', f)
    if m and m.group(3) == st: stem[(m.group(1) or '', m.group(2), m.group(4))][st].add(k)
    m = re.match(r'^(.*@z0x[0-9a-f]+)\+0x[0-9a-f]+$', src)
    if m: stream[m.group(1)][st].add(k)
progs = set(); n1 = n2 = big = 0
for g in stem.values():
    for v, p in itertools.product(g.get('vs', ()), g.get('ps', ())): progs.add((v, p)); n1 += 1
for g in stream.values():
    if len(g.get('vs', ())) > MAXN or len(g.get('ps', ())) > MAXN: big += 1; continue
    for v, p in itertools.product(g.get('vs', ()), g.get('ps', ())): progs.add((v, p)); n2 += 1
with open(out, 'w') as fo:
    fo.write('# vs键\ths键\tds键\tgs键\tps键\n')
    for v, p in sorted(progs): fo.write(f'{v}\t-\t-\t-\t{p}\n')
print(f'同主干文件 {sum(1 for g in stem.values() if g.get("vs") and g.get("ps"))} 组 {n1} 对；同一压缩流 {sum(1 for g in stream.values() if g.get("vs") and g.get("ps"))} 个 {n2} 对'
      f'（超过 {MAXN} 支不配 {big} 个）；去重程序 {len(progs)}', file=sys.stderr)
