#!/usr/bin/env python3
# 管线首用表收集器单测（graphics/tools/shbake/psouse.py）：约 0.1 秒，退出 0 = 全过。期望按规则手写，不跑被测实现推期望：
#   作业 A（正式，包名 io.s2arm.t）：f 键 k1 帧 40、b 键 k2 帧 7、一行坏格式（缺键编码）；作业 B（正式）：k1 帧 12（更早）、新 f 键 k3 帧 90；
#   作业 C（实验，包名 io.s2arm-exp.t）：f 键 k4 帧 1——不收。表里原有 b 键 k5 帧 3（只增不减，留着）
#   → 表 = 3 b k5、7 b k2、12 f k1、90 f k3（按帧升序），4 条；再跑一遍表不变（原样「表 4 → 4」）
import os, subprocess, sys, tempfile
H = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
T = tempfile.mkdtemp(prefix='t_psouse.'); fail = 0; n = 0
def ck(ok, msg):
    global fail, n
    n += 1; print(('✓ ' if ok else '✗ ') + msg); fail += 0 if ok else 1
P1, P2 = 's00000000000000a1,s00000000000000b1', 's00000000000000a2_wl'
def job(name, bundle, lines):
    d = os.path.join(T, 'sched', 'jobs', name); os.makedirs(os.path.join(d, 'out_1'))
    open(os.path.join(d, 'job.env'), 'w').write(f'GAME=t\nBUNDLE={bundle}\n')
    open(os.path.join(d, 'out_1', 'host.log'), 'w').write(''.join(f'[gal] {l}\n' for l in lines))
job('t_1', 'io.s2arm.t', [f'管线首用 v1 672 40 f {P1} 01-20ff', f'管线首用 v1 672 7 b {P2} -ff-ff-a2', f'管线首用 v1 672 9 f {P1}'])
job('t_2', "'io.s2arm.t'", [f'管线首用 v1 672 12 f {P1} 01-20ff', f'管线首用 v1 672 90 f {P1} 02-20ff'])
job('t_3', 'io.s2arm-exp.t', [f'管线首用 v1 672 1 f {P1} 03-20ff'])
os.makedirs(os.path.join(T, 'col', 't'))
open(os.path.join(T, 'col', 't', 'pso_use.tsv'), 'w').write(f'# 旧表\n3\tb\t{P1}\t05-20ff\n')
env = dict(os.environ, S2A_SHCOLLECT=os.path.join(T, 'col'), S2A_SCHED_DIR=os.path.join(T, 'sched'))
def run():
    r = subprocess.run([sys.executable, os.path.join(H, 'psouse.py'), 't'], capture_output=True, text=True, env=env)
    rows = [l.rstrip('\n') for l in open(os.path.join(T, 'col', 't', 'pso_use.tsv'), encoding='utf-8') if not l.startswith('#')]
    return r, rows
r, rows = run()
want = [f'3\tb\t{P1}\t05-20ff', f'7\tb\t{P2}\t-ff-ff-a2', f'12\tf\t{P1}\t01-20ff', f'90\tf\t{P1}\t02-20ff']
ck(r.returncode == 0 and rows == want, f'表 = 手算 4 条（旧 k5 留、k1 取更早帧 12、实验局 k4 不收、坏行不收），实得 {rows}（{r.stdout.strip()}{r.stderr[-200:]}）')
r2, rows2 = run()
ck(rows2 == want and '表 4 → 4' in r2.stdout, f'再跑一遍表不变（{r2.stdout.strip()}）')
import shutil; shutil.rmtree(T, ignore_errors=True)
print(f'psouse 单测：{n} 项，失败 {fail}')
sys.exit(1 if fail else 0)
