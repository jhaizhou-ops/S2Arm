#!/usr/bin/env python3
# run_pairs.py 单测：期望值手写。P 行并入配对表、并集外与坏行滤掉、已有不重复、目录来源与文件来源都读、跑两遍结果不变；反证：没有 P 行时配对表逐字不变
import os, subprocess, sys, tempfile
H = os.path.dirname(os.path.abspath(__file__)); T = os.path.join(H, '..', 'run_pairs.py')
A, B, C, D, X = 'a' * 16, 'b' * 16, 'c' * 16, 'd' * 16, 'e' * 16
fails = 0
def check(name, ok):
    global fails
    print(('✓ ' if ok else '✗ ') + name); fails += not ok
with tempfile.TemporaryDirectory() as t:
    pairs, union = os.path.join(t, 'shader_pairs.tsv'), os.path.join(t, 'union_keys.tsv')
    open(pairs, 'w').write('# 头\n' + f'{A}\t{B}\n')
    open(union, 'w').write('\n'.join([A, B, C, D]) + '\n')
    f1 = os.path.join(t, 'pso_user.tsv'); open(f1, 'w').write(f'S\t{A}_b\t0\nP\t{A}\t{B}\nP\t{C}\t{D}\nP\t{C}\t{X}\nP\tbad\t{D}\nR\t00\n')
    d = os.path.join(t, 'seed'); os.mkdir(d); open(os.path.join(d, 'job1.tsv'), 'w').write(f'P\t{D}\t{A}\nP\t{C}\t{D}\n')
    run = lambda *src: subprocess.run([sys.executable, T, pairs, union, *src], capture_output=True, text=True)
    r = run(f1, d, os.path.join(t, '没有'))
    got = open(pairs).read()
    check('新对 C→D、D→A 并入，已有 A→B 不重复，并集外 C→X 与坏行滤掉', got == '# 头\n' + f'{A}\t{B}\n{C}\t{D}\n{D}\t{A}\n')
    check('汇总行：P 行 5（C→D 两处各算），并集外 1，新并入 2', r.stdout.strip().endswith('P 行 5，不在本次并集 1，新并入配对表 2'))
    run(f1, d); check('跑第二遍不变', open(pairs).read() == got)
    open(pairs, 'w').write('# 头\n' + f'{A}\t{B}\n'); f2 = os.path.join(t, 'only_r.tsv'); open(f2, 'w').write('R\t00\nS\tx\t0\n')
    run(f2); check('反证：来源里没有 P 行时配对表逐字不变', open(pairs).read() == '# 头\n' + f'{A}\t{B}\n')
print(f'run_pairs：{"全过" if not fails else f"{fails} 项不符"}')
sys.exit(1 if fails else 0)
