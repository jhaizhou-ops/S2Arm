#!/usr/bin/env python3
# 采样模拟变体出包预编单测（graphics/tools/direct/se_want.py，11-01 出包线，缺口族 31）：python3 tests/se_want_test.py，约 1 秒
# 期望（按直连线写给出包线的接口手写，不跑被测实现推）：
#   ① R 行：432 字节 skey，第 24–47 字节放片元键 C 串、第 157 字节 fc = 0x02 → 收这个键；fc = 0x01（没有 SE_RD 位）→ 不收
#   ② C 行：fc 十六进制 0x6（含 2）→ 收；0x4 → 不收
#   ③ 不在本次并集里的键不收；长度不是 432 字节的 R 行、坏十六进制不抛错、不收；目录来源只读 .tsv
#   ④ 表 = 注释一行 + 收下的键按序；汇总句写见过 3 个、本次 2 个
#   原 ⑤ dsh_batch --samp-emu 随出库链挪进 C# 删除（整份出库 dsh_batch build 进程内直接调 DshCompiler.FsRd）：FsRd 的改写本身由 t_dsh.sh ⑥ 逐函数金样（fs_rd）守，
#   整份出库读 se_want.tsv、按键出 <键>_se 的接线由 graphics/tools/direct/tests/t_dmsh_reuse.py 守
import os, subprocess, sys, tempfile
H = os.path.dirname(os.path.abspath(__file__)); R = os.path.abspath(os.path.join(H, '..'))
fail = 0
def ck(name, ok, got=''):
    global fail
    print(('✓ ' if ok else '✗ ') + name + (f'（实得 {got}）' if got != '' else '')); fail += 0 if ok else 1
def skey(fs, fc):
    b = bytearray(432); b[24:24 + len(fs)] = fs.encode(); b[157] = fc; return bytes(b).hex()
A, B, C1, C2, X = 'a' * 16, 'b' * 16, 'c' * 16, 'd' * 16, 'e' * 16
d = tempfile.mkdtemp(); src = os.path.join(d, 'runs'); os.makedirs(src)
open(os.path.join(src, 'r1.tsv'), 'w').write(f'R\t{skey(A, 2)}\nR\t{skey(B, 1)}\nC\t{C1}\t6\nC\t{C2}\t4\nR\t{skey(X, 2)}\nR\tabcd\nR\t{"zz" * 432}\nP\t{A}\t{B}\n')
open(os.path.join(src, 'ignore.txt'), 'w').write(f'C\t{B}\t2\n')
union = os.path.join(d, 'union.tsv'); open(union, 'w').write('\n'.join([A, B, C1, C2]) + '\n')
out = os.path.join(d, 'se_want.tsv')
r = subprocess.run([sys.executable, os.path.join(R, 'graphics/tools/direct/se_want.py'), out, union, src, os.path.join(d, 'missing.tsv')], capture_output=True, text=True)
body = [l for l in open(out).read().splitlines() if not l.startswith('#')] if os.path.exists(out) else None
ck('①② R 行 fc&2 收、C 行 fc&2 收，其余不收', body == [A, C1], body)
ck('③ 不在并集 / 坏行 / 非 .tsv 来源不收，不抛错', r.returncode == 0 and X not in (body or []) and B not in (body or []), r.returncode)
ck('④ 表头一行注释、汇总句', open(out).readline().startswith('#') and r.stdout.strip().splitlines()[-1] == '采样模拟变体请求：跑局见过 3 个键，本次出库里有 2 个（预编 <键>_se）', r.stdout.strip())
print('se_want 单测全过' if not fail else f'se_want 单测有 {fail} 项不过'); sys.exit(1 if fail else 0)
