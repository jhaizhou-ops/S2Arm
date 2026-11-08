#!/usr/bin/env python3
# 特化管线表收集器（graphics/tools/shbake/specpipe.py）单测：期望手写。夹具行照 gal_core.m gal_pso_note_desc 的输出格式（带「[gal] 」前缀）。
#   ① 给局目录：v2 / b2 行都收、格式不对的不收；② 不给目录：只收正式局（job.env BUNDLE 不是 io.s2arm-exp.*），实验局跳过（10-22 共享收集目录只收正式局）
import os, subprocess, sys, tempfile
H = os.path.dirname(os.path.abspath(__file__)); S = os.path.join(H, '..', 'specpipe.py')
fail = 0; n = 0
def check(c, msg):
    global fail, n
    n += 1
    if not c: fail += 1; print('  ✗', msg)
T = tempfile.mkdtemp(prefix='t_specpipe_')
V2 = 'v2 s1000000000000000 s2000000000000000 3 1 0 0 1 0:90:9:1:0:4:5:4:1:1'
B2 = 'b2 s1000000000000000_wl s2000000000000000 0 1 0 0 1'
A = os.path.join(T, 'runA'); os.makedirs(A)
open(os.path.join(A, 'host.log'), 'w', encoding='utf-8').write('\n'.join(['[gal] 特化管线 ' + V2, '[gal] 特化管线 ' + B2, '[gal] 特化管线 v2 s1000 s2000 3 1 0 0 1', '[gal] 特化管线 v1 s1000000000000000 - 0 1 0 0']) + '\n')
def rows(col, g='g'):
    p = os.path.join(col, g, 'spec_pipes.tsv')
    return [l.rstrip('\n') for l in open(p, encoding='utf-8') if not l.startswith('#')] if os.path.exists(p) else []
C1 = os.path.join(T, 'col1')
r = subprocess.run([sys.executable, S, 'g', A], env=dict(os.environ, S2A_SHCOLLECT=C1), capture_output=True, text=True)
check(r.returncode == 0 and rows(C1) == sorted([V2, B2]), f'① 期望收 v2 + b2 两条、格式不对的两条不收，实得 {rows(C1)}（{r.stderr.strip()}）')
SD = os.path.join(T, 'sched'); C2 = os.path.join(T, 'col2')
for jd, bid, line in (('g_1', 'io.s2arm.g', V2), ('g_2', 'io.s2arm-exp.g', B2)):
    o = os.path.join(SD, 'jobs', jd, 'out_1'); os.makedirs(o)
    open(os.path.join(SD, 'jobs', jd, 'job.env'), 'w').write(f'DEV=1\nBUNDLE={bid}\nGAME=g\n')
    open(os.path.join(o, 'host.log'), 'w', encoding='utf-8').write('[gal] 特化管线 ' + line + '\n')
r = subprocess.run([sys.executable, S, 'g'], env=dict(os.environ, S2A_SHCOLLECT=C2, S2A_SCHED_DIR=SD), capture_output=True, text=True)
check(rows(C2) == [V2], f'② 不给目录时期望只收正式局那条（实验局跳过），实得 {rows(C2)}')
__import__('shutil').rmtree(T, ignore_errors=True)
print(f't_specpipe：{n} 项，失败 {fail}')
sys.exit(1 if fail else 0)
