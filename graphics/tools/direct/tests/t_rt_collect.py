#!/usr/bin/env python3
# 现编回收 R1 单测（graphics/tools/direct/rt_collect.py parse，手造两台设备拉回的兜底目录，约 1 秒）：期望表按规则手写
#   甲：键 a（vs）、b（ps）兜底现编，b 另有输出类型变体 u=0x5 s=0，c 的曲面前顶点核；还有一个坏 json、一个键与文件名不符的 json、一个认不出的文件
#   乙：键 b（重复）、d（ps），b 的同一变体（重复）+ 另一变体 u=0x1 s=0x2，以及一起拉回的管线表 pso_user.tsv（归 pso_seed.py，不算认不出）
#   期望 rt_keys = a / b / d 三行（重复去掉、坏的不进）；rt_fout = b 1 2、b 5 0 两行；rt_vt = c；认不出 / 坏文件 3 个
import json, os, subprocess, sys, tempfile
H = os.path.dirname(os.path.abspath(__file__)); RC = os.path.join(H, '..', 'rt_collect.py')
A, B, C, D = '0000000000000a0a', '0000000000000b0b', '0000000000000c0c', '0000000000000d0d'
n = bad = 0
def ck(name, ok):
    global n, bad
    n += 1; bad += 0 if ok else 1; print(('✓ ' if ok else '✗ ') + name)
with tempfile.TemporaryDirectory() as t:
    d1, d2, o = os.path.join(t, 'dev1'), os.path.join(t, 'dev2'), os.path.join(t, 'out')
    os.makedirs(d1); os.makedirs(d2)
    def js(d, k, st, key=None): json.dump({'key': (key or k) + '_b', 'stage': st, 'chain': 'abc123def456'}, open(os.path.join(d, k + '_b.json'), 'w'))
    def touch(d, f): open(os.path.join(d, f), 'w').write('// msl')
    js(d1, A, 'vs'); touch(d1, A + '_b.metal'); js(d1, B, 'ps'); touch(d1, B + '_t5_0.metal'); touch(d1, C + '_vt.metal')
    open(os.path.join(d1, '0000000000000e0e_b.json'), 'w').write('{坏')
    js(d1, '0000000000000f0f', 'ps', key=A)   # 键与文件名不符
    touch(d1, 'notes.txt')
    js(d2, B, 'ps'); js(d2, D, 'ps'); touch(d2, B + '_t5_0.metal'); touch(d2, B + '_t1_2.metal'); open(os.path.join(d2, 'pso_user.tsv'), 'w').write('S\tx\t0\n')   # 一起拉回的管线表：不算认不出
    r = subprocess.run([sys.executable, RC, 'parse', o, d1, d2], capture_output=True, text=True)
    rows = lambda f: [l.rstrip('\n') for l in open(os.path.join(o, f)) if not l.startswith('#')]
    ck(f'rt_keys = a vs / b ps / d ps（{rows("rt_keys.tsv")}）', rows('rt_keys.tsv') == [f'{A}\tvs\tabc123def456', f'{B}\tps\tabc123def456', f'{D}\tps\tabc123def456'])
    ck(f'rt_fout = b 1 2 / b 5 0（{rows("rt_fout.tsv")}）', rows('rt_fout.tsv') == [f'{B}\t1\t2', f'{B}\t5\t0'])
    ck(f'rt_vt = c（{rows("rt_vt.tsv")}）', rows('rt_vt.tsv') == [C])
    ck(f'认不出 / 坏文件 3 个（{r.stdout.strip().splitlines()[0] if r.stdout else r.stderr[-200:]}）', '认不出 / 坏文件 3' in r.stdout)
    r2 = subprocess.run([sys.executable, RC, 'parse', o, os.path.join(t, 'none')], capture_output=True, text=True)
    ck('目录不存在（设备没拉到）→ 三张空表、退出 0', r2.returncode == 0 and rows('rt_keys.tsv') == [] and rows('rt_fout.tsv') == [] and rows('rt_vt.tsv') == [])
print(f't_rt_collect：{n} 项，失败 {bad}')
sys.exit(1 if bad else 0)
