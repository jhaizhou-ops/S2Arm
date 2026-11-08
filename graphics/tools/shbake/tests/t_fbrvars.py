#!/usr/bin/env python3
# 读帧缓冲变体请求收集器（graphics/tools/shbake/fbrvars.py）单测：夹具行照抄 graphics/metal 单测 t_fbrp 真日志（gal_fbr.m 的 GLOG 输出，带「[gal] 」前缀）。
# 期望手写：两局各收一部分 → 表 = 并集、去重、排序；格式不对的行（缺 v1、键不是 16 位、槽 ≥ 8、ydown 不是 0/1）不收；表只增不减
import os, subprocess, sys, tempfile
H = os.path.dirname(os.path.abspath(__file__)); S = os.path.join(H, '..', 'fbrvars.py')
fail = 0; n = 0
def check(c, msg):
    global fail, n
    n += 1
    if not c: fail += 1; print('  ✗', msg)
T = tempfile.mkdtemp(prefix='t_fbrvars_')
A, B = os.path.join(T, 'runA'), os.path.join(T, 'runB'); os.makedirs(A); os.makedirs(B)
REAL = '[gal] 读帧缓冲变体缺 v1 5f505b437920a37b 74b92875a94dfcf6 1 128:1'
open(os.path.join(A, 'host.log'), 'w', encoding='utf-8').write('\n'.join([
    '[gal] 离线着色器库：4 支',
    REAL,
    REAL,
    '[gal] 读帧缓冲变体缺 v1 5f505b437920a37b 74b92875a94dfcf6 2 128:1',      # ydown 2
    '[gal] 读帧缓冲变体缺 v1 5f505b437920a37 74b92875a94dfcf6 1 128:1',       # 顶点键 15 位
    '[gal] 读帧缓冲变体缺 v1 5f505b437920a37b 74b92875a94dfcf6 1 128:8',      # 槽 8
    '[gal] 读帧缓冲变体缺 5f505b437920a37b 74b92875a94dfcf6 1 128:1',         # 缺 v1
]) + '\n')
open(os.path.join(B, 'host.log'), 'w', encoding='utf-8').write('[gal] 读帧缓冲变体缺 v1 0000000000000001 00000000000000ff 0 3:0 7:2\n' + REAL + '\n')
env = dict(os.environ, S2A_SHCOLLECT=os.path.join(T, 'col'))
OUT = os.path.join(T, 'col', 'g', 'fbr_vars.tsv')
def rows(): return [l.rstrip('\n') for l in open(OUT, encoding='utf-8') if not l.startswith('#')]
r = subprocess.run([sys.executable, S, 'g', A], env=env, capture_output=True, text=True)
check(r.returncode == 0, f'第一局退出码期望 0，实得 {r.returncode}：{r.stderr}')
check(rows() == ['v1 5f505b437920a37b 74b92875a94dfcf6 1 128:1'], f'第一局期望只收 1 条（真日志那行），实得 {rows()}')
r = subprocess.run([sys.executable, S, 'g', B], env=env, capture_output=True, text=True)
check(rows() == ['v1 0000000000000001 00000000000000ff 0 3:0 7:2', 'v1 5f505b437920a37b 74b92875a94dfcf6 1 128:1'], f'第二局后期望并集 2 条、排序，实得 {rows()}')
r = subprocess.run([sys.executable, S, 'g', os.path.join(T, 'empty')], env=env, capture_output=True, text=True)
check(len(rows()) == 2, f'没有局可扫时期望表不缩，实得 {len(rows())} 条')
check(open(OUT, encoding='utf-8').readline().startswith('# 读帧缓冲变体请求表'), '表头期望注释行')
# 不给目录：只收正式局（job.env BUNDLE 不是 io.s2arm-exp.*），实验局跳过（10-22 共享收集目录只收正式局）
SD = os.path.join(T, 'sched'); C2 = os.path.join(T, 'col2')
for jd, bid, line in (('g_1', 'io.s2arm.g', '[gal] 读帧缓冲变体缺 v1 1111111111111111 2222222222222222 0 128:1'), ('g_2', 'io.s2arm-exp.g', '[gal] 读帧缓冲变体缺 v1 3333333333333333 4444444444444444 0 128:1')):
    o = os.path.join(SD, 'jobs', jd, 'out_1'); os.makedirs(o)
    open(os.path.join(SD, 'jobs', jd, 'job.env'), 'w').write(f'DEV=1\nBUNDLE={bid}\nGAME=g\n')
    open(os.path.join(o, 'host.log'), 'w', encoding='utf-8').write(line + '\n')
r = subprocess.run([sys.executable, S, 'g'], env=dict(os.environ, S2A_SHCOLLECT=C2, S2A_SCHED_DIR=SD), capture_output=True, text=True)
R2 = [l.rstrip('\n') for l in open(os.path.join(C2, 'g', 'fbr_vars.tsv'), encoding='utf-8') if not l.startswith('#')] if os.path.exists(os.path.join(C2, 'g', 'fbr_vars.tsv')) else []
check(R2 == ['v1 1111111111111111 2222222222222222 0 128:1'], f'不给目录时期望只收正式局那 1 条（实验局 io.s2arm-exp.* 跳过），实得 {R2}')
__import__('shutil').rmtree(T, ignore_errors=True)
print(f't_fbrvars：{n} 项，失败 {fail}')
sys.exit(1 if fail else 0)
