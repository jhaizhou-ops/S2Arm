#!/usr/bin/env python3
# 外部程序表读取器单测（10-21 pair）：file_pairs.py（同主干文件名 / 同一压缩流）与 rdhs_programs.py --vs-only。输入手搓，期望手算。
# 旧代码反证：没有 file_pairs.py（文件不存在 = 第 1–3 项红）；旧 rdhs_programs.py 不认 --vs-only（第 4 项红）。用法：t_programs.py [shbake 目录]；退出 0 = 全过
import sys, os, struct, subprocess, tempfile, shutil
D = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
T = tempfile.mkdtemp(); fail = 0; n = 0
def check(ok, what):
    global fail, n
    n += 1; print(('✓ ' if ok else '✗ ') + what); fail += 0 if ok else 1
def table(path):
    return sorted(tuple(l.rstrip('\n').split('\t')) for l in open(path) if l.strip() and not l.startswith('#')) if os.path.exists(path) else None
rows = os.path.join(T, 'rows.tsv')
R = [('v1', 'vs', 'bin/st/leaves_vs.glslobj', 0), ('v2', 'vs', 'bin/st/leaves_vs.glslobj_nowind', 0),
     ('p1', 'ps', 'bin/st/leaves_ps.glslobj', 0), ('p2', 'ps', 'bin/st/leaves_ps.glslobj_dissolve_free', 0),
     ('p3', 'ps', 'bin/st/grass_ps.glslobj', 0),                                   # 没有同主干 vs：不配
     ('v4', 'vs', 'other/leaves_vs.glslobj', 0),                                   # 不同目录：不和 bin/st 的配
     ('a1', 'vs', 'C.cpk@z0x100+0x40', 0), ('b1', 'ps', 'C.cpk@z0x100+0x900', 0), ('b2', 'ps', 'C.cpk@z0x100+0x1200', 0),
     ('a2', 'vs', 'C.cpk@z0x5000+0x40', 0), ('c1', 'cs', 'C.cpk@z0x5000+0x800', 0)]   # 只有 vs + cs 的流：不出程序
R += [(f'bv{i}', 'vs', 'C.cpk@z0x9000+0x%x' % (i * 0x100), 0) for i in range(17)] + [('bp', 'ps', 'C.cpk@z0x9000+0x9999', 0)]   # 17 支 vs > 16：不配
open(rows, 'w').write('# 键\t阶段\t来源\t变体号\n' + ''.join('\t'.join(map(str, r)) + '\n' for r in R))
out = os.path.join(T, 'fp.tsv'); r = subprocess.run([sys.executable, os.path.join(D, 'file_pairs.py'), rows, out], capture_output=True, text=True)
got = table(out) or []
st = sorted((v, '-', '-', '-', p) for v in ('v1', 'v2') for p in ('p1', 'p2'))
sm = sorted([('a1', '-', '-', '-', 'b1'), ('a1', '-', '-', '-', 'b2')])
check(all(x in got for x in st), f'同主干 leaves：v1/v2 × p1/p2 = 4 个程序 → 真结果 {[x for x in got if x in st]}')
check(all(x in got for x in sm) and not any(x[0] == 'a2' for x in got), f'同一压缩流：a1 × b1/b2，只有 vs + cs 的流不出 → 真结果 {[x for x in got if x[0] in ("a1", "a2")]}')
check(len(got) == 6 and 'v4' not in {x[0] for x in got} and not any(x[0].startswith('bv') for x in got), f'不同目录不配、超过 16 支的流不配：合计 6 个 → 真结果 {len(got)} 个（rc={r.returncode}）')
# rdhs --vs-only：手搓一份 shadernx.cache（布局见 rdhs_programs.py 头注释）：着色器区 3 支（vs h1、ps h2、vs h3），条目区 2 条（h1+h2、h3+h2）
def cr2w(s): b = s.encode(); return bytes([0x80 | len(b)]) + b
sh = b''; offs = {}
for h in (b'H1H1H1H1', b'H2H2H2H2', b'H3H3H3H3'):
    offs[h] = len(sh) + 17; sh += h + b'\x01' + struct.pack('<II', 16, 16) + b'\x28\xb5\x2f\xfd' + bytes(12)
ent = b''
for i, (v, p) in enumerate(((b'H1H1H1H1', b'H2H2H2H2'), (b'H3H3H3H3', b'H2H2H2H2'))):
    slots = [v, p, bytes(8), bytes(8), bytes(8), bytes(8)]
    ent += struct.pack('<IIQQ', i, 0, 0, 0) + cr2w(f'm.w2mg [{i}] ') + struct.pack('<I', i) + b''.join(slots) + struct.pack('<II', 0, 0) + struct.pack('<I', 0) + struct.pack('<I', 0)
data = sh + ent + struct.pack('<IIQQQQ', 3, 2, 0, len(sh), len(ent), len(sh)) + b'RDHS' + struct.pack('<I', 3)
os.makedirs(os.path.join(T, 'romfs', 'c')); open(os.path.join(T, 'romfs', 'c', 'shadernx.cache'), 'wb').write(data)
rows2 = os.path.join(T, 'rows2.tsv')
open(rows2, 'w').write('# 键\t阶段\t来源\t变体号\n' + ''.join(f'{k}\t{s}\tc/shadernx.cache@zs{offs[h]:#x}@adj0x0\t0\n' for k, s, h in (('k1', 'vs', b'H1H1H1H1'), ('k2', 'ps', b'H2H2H2H2'), ('k3', 'vs', b'H3H3H3H3'))))
out2 = os.path.join(T, 'rd.tsv')
r = subprocess.run([sys.executable, os.path.join(D, 'rdhs_programs.py'), rows2, os.path.join(T, 'romfs'), '-o', out2, '--vs-only'], capture_output=True, text=True)
want = sorted([('k1', '-', '-', '-', 'k2'), ('k3', '-', '-', '-', 'k2'), ('k1', '-', '-', '-', '-'), ('k3', '-', '-', '-', '-')])
got2 = table(out2) if r.returncode == 0 else None
check(got2 == want, f'rdhs --vs-only：两条目 → k1+k2、k3+k2，另加 k1、k3 只顶点，共 4 个 → 真结果 {got2}（rc={r.returncode}）')
shutil.rmtree(T)
print(f'期望 外部程序表读取器 {n} 项全过 → 真结果 失败 {fail} / {n}')
sys.exit(1 if fail else 0)
