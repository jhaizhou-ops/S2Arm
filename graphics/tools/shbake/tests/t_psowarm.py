#!/usr/bin/env python3
# 提前热程序表单测（graphics/tools/shbake/psowarm.py）：约 0.1 秒，退出 0 = 全过。期望按规则手写，不跑被测实现推期望：
#   programs.tsv：0 = A,B；1 = A,B（同组函数、特化不同）；-1 = C,D（没写进缓存）；2 = E（计算）；3 = F,G
#   pso_use.tsv：50 f F,G；7 b A,B；9 f A,B（同组重复）；3 f E；1 f C,D（包里没有）；60 f F_lb,G（带后缀，同组）；一行坏格式
#   → 输出按首用帧升序、每组取第一个程序号：「2 3 E」「0 7 A,B」「3 50 F,G」；对不上 1 组（C,D）
import os, subprocess, sys, tempfile
H = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
T = tempfile.mkdtemp(prefix='t_psowarm.'); fail = 0; n = 0
def ck(ok, msg):
    global fail, n
    n += 1; print(('✓ ' if ok else '✗ ') + msg); fail += 0 if ok else 1
k = {c: '00000000000000' + c.lower() + '1' for c in 'ABCDEFG'}
s = lambda *cs: ','.join('s' + k[c] for c in cs)
with open(os.path.join(T, 'programs.tsv'), 'w') as f:
    f.write('idx\torigin\tstatus\tkind\tsource\tstages\tspv\tms\terr\n')
    for idx, cs in ((0, 'AB'), (1, 'AB'), (-1, 'CD'), (2, 'E'), (3, 'FG')):
        f.write(f'{idx}\trule\tok\tgraphics\tsrc\tst\t{",".join(k[c] for c in cs)}\t1.0\t\n')
with open(os.path.join(T, 'pso_use.tsv'), 'w') as f:
    f.write(f'50\tf\t{s("F", "G")}\t00-ff\n7\tb\t{s("A", "B")}\t00-ff\n9\tf\t{s("A", "B")}\t01-ff\n3\tf\t{s("E")}\t00-ff\n1\tf\t{s("C", "D")}\t00-ff\n')
    f.write(f'60\tf\ts{k["F"]}_lb,s{k["G"]}\t02-ff\n坏行\n')
out = os.path.join(T, 'pso_warm.tsv')
r = subprocess.run([sys.executable, os.path.join(H, 'psowarm.py'), os.path.join(T, 'programs.tsv'), os.path.join(T, 'pso_use.tsv'), out], capture_output=True, text=True)
ck(r.returncode == 0, f'退出 0（实得 {r.returncode}：{r.stderr.strip()[:200]}）')
rows = [l.rstrip('\n').split('\t') for l in open(out) if not l.startswith('#')] if os.path.exists(out) else []
ck(rows == [['2', '3', s('E')], ['0', '7', s('A', 'B')], ['3', '50', s('F', 'G')]], f'三行按首用帧升序、每组取第一个程序号（实得 {rows}）')
ck('对上 3 个程序，对不上 1' in r.stdout, f'读数行：对上 3、对不上 1（实得 {r.stdout.strip()}）')
r2 = subprocess.run([sys.executable, os.path.join(H, 'psowarm.py'), os.path.join(T, 'programs.tsv')], capture_output=True, text=True)
ck(r2.returncode == 2, f'少参数退出 2（实得 {r2.returncode}）')
print(f't_psowarm：{n} 项，失败 {fail}')
sys.exit(1 if fail else 0)
