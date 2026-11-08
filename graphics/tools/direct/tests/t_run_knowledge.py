#!/usr/bin/env python3
# 跑局知识快照单测（graphics/tools/direct/run_knowledge.py，审计 #1534 P1-54 B1；手造来源，约 1 秒）。期望按规则手写，不跑被测实现推期望：
#   来源一（文件 a.tsv）：S A、P(A,B)、R1(A→B，浮点画布)、R2(A→C，画布 0 = 无符号整数格式 13)、C D fc=2（采样模拟）、P(坏键)、R(长度不对)、Q 杂行、S A（重复）
#   来源二（目录 dev/：b.tsv + 非 .tsv 文件）：P(C,D)、P(A,B)（与来源一重复）、R1（重复）、R3(B→D，片元字节 157 = 2：采样模拟)
#   期望 pairs = P(A,B)、P(C,D)（去重、排序）；fout_want = C 1 0（R2 画布 0 无符号）；se_want = D（C 行）、D（R3 片元）→ 去重后 D 一个；
#        seen = S A / R1 / R2 / C D / R3（来源先后、各自行序、去重；P / 坏行 / 杂行不进）
#   不变性：同内容复制一份进另一个目录、换文件名 / 换目录名（= 换来源机器）、只改修改时间 → 四张表逐字节相同；来源先后、P 行先后都换 → 进直连键的三张表逐字节相同
#   等价（产出等价，同一组来源，新旧流程比出库消费者的产物）：fout_want.py 直读来源 = 快照 fout_want.tsv 逐字节；se_want.py 直读来源 = se_want.py --keys 快照 逐字节；
#        pso_seed.py 直读来源 = pso_seed.py 读快照 seen.tsv 的种子表数据行逐字节；run_pairs.py 直读来源与读快照 pairs.tsv 并出的配对表行集合相同
#   程序号：给产物根目录 → 取 unpack.tsv 的 title_id；没有 unpack.tsv → 读 exefs/main.npdm（META +0x70 → ACI0 +0x10）；不给来源 → S2A_PSO_SOURCES，再没有 → <S2A_RUN_ROOT>/s2arm/pso_seed/<程序号>
#   反证：没有任何来源 → 四张表只有表头
import json, os, shutil, struct, subprocess, sys, tempfile
H = os.path.dirname(os.path.abspath(__file__)); D = os.path.dirname(H); RK = os.path.join(D, 'run_knowledge.py')
L = json.load(open(os.path.join(D, 'pso_layout.json'), encoding='utf-8'))
A, B, C, X = 'a' * 16, 'b' * 16, 'c' * 16, 'e' * 16
DK = 'd' * 16
n = bad = 0
def ck(name, ok):
    global n, bad
    n += 1; bad += 0 if ok else 1; print(('✓ ' if ok else '✗ ') + name)
def rrow(vs, fs, cfmt0=0, fc=0):   # 一条 R 行：顶点 / 片元键名（以 0 结尾）、画布 0 的像素格式、字节 157（采样模拟位 2）；其余 0
    b = bytearray(L['skey_size']); b[0:24] = (vs + '_b').encode().ljust(24, b'\0'); o, w = L['fs']; b[o:o + w] = (fs + '_b').encode().ljust(w, b'\0')
    b[L['cfmt']:L['cfmt'] + 4] = struct.pack('<I', cfmt0); b[157] = fc
    return 'R\t' + b.hex()
assert 13 in L['uint_formats'] and 13 not in L['sint_formats']
R1, R2, R3 = rrow(A, B), rrow(A, C, cfmt0=13), rrow(B, DK, fc=2)
SRC1 = f'# user list\nS\t{A}_b\t0\nP\t{A}\t{B}\n{R1}\n{R2}\nC\t{DK}\t2\nP\tnot-a-key\t{B}\nR\t00ff\nQ\tjunk\nS\t{A}_b\t0\n'
SRC2 = f'P\t{C}\t{DK}\nP\t{A}\t{B}\n{R1}\n{R3}\n'
run = lambda *a, env=None: subprocess.run([sys.executable, *a], capture_output=True, text=True, env=env)
TABLES = ('pairs', 'fout_want', 'se_want', 'seen')
def snap(out, tid, *src, env=None):
    r = run(RK, out, tid, *src, env=env)
    return r, {t: open(os.path.join(out, t + '.tsv'), 'rb').read() for t in TABLES} if r.returncode == 0 else {}
data = lambda b: [l for l in b.decode().split('\n') if l and not l.startswith('#')]
with tempfile.TemporaryDirectory() as t:
    p = lambda *a: os.path.join(t, *a)
    os.makedirs(p('m1', 'dev')); open(p('m1', 'a.tsv'), 'w').write(SRC1); open(p('m1', 'dev', 'b.tsv'), 'w').write(SRC2); open(p('m1', 'dev', 'notes.txt'), 'w').write(f'P\t{X}\t{X}\n')
    r, k1 = snap(p('k1'), '0100abcd00000000', p('m1', 'a.tsv'), p('m1', 'dev'), p('没有'))
    ck(f'退出 0、汇总行（{r.stdout.strip()[:120]}）', r.returncode == 0 and '来源 2 份；配对 2、输出类型变体 1、采样模拟 1、管线种子行 5' in r.stdout)
    ck('pairs = P(A,B)、P(C,D)：去重排序、坏键与非 .tsv 文件不进', data(k1.get('pairs', b'')) == [f'P\t{A}\t{B}', f'P\t{C}\t{DK}'])
    ck('fout_want = C 无符号 1 有符号 0（R2 画布 0 是无符号整数格式）', data(k1.get('fout_want', b'')) == [f'{C}\t1\t0'])
    ck('se_want = D（C 行 fc=2 与 R3 字节 157=2 去重成一个）', data(k1.get('se_want', b'')) == [DK])
    ck('seen = S A / R1 / R2 / C D / R3（首用序去重，P / 坏行 / 杂行不进）', data(k1.get('seen', b'')) == [f'S\t{A}_b\t0', R1, R2, f'C\t{DK}\t2', R3])
    # 不变性：另一台机器上同样的内容（目录名、文件名都不同），再加一份同内容的副本、改修改时间、调换 P 行先后
    os.makedirs(p('机器二', 'x')); open(p('机器二', 'mac_mini.tsv'), 'w').write(SRC1); shutil.copy(p('m1', 'dev', 'b.tsv'), p('机器二', 'x', 'job_42.tsv'))
    shutil.copy(p('机器二', 'mac_mini.tsv'), p('机器二', 'x', 'zz_copy.tsv')); os.utime(p('机器二', 'mac_mini.tsv'), (1, 1))
    r, k2 = snap(p('k2'), '0100ABCD00000000', p('机器二', 'mac_mini.tsv'), p('机器二', 'x'))
    ck('换来源路径 / 文件名（换机器）、多一份同内容副本、改修改时间 → 四张表逐字节相同', r.returncode == 0 and k2 == k1)
    open(p('机器二', 'x', 'job_42.tsv'), 'w').write(f'P\t{C}\t{DK}\n{R1}\n{R3}\nP\t{A}\t{B}\n')   # 同 SRC2 的行，只换先后（不排序的实现在这里会把 C→D 排到 A→B 前面）
    r, k3 = snap(p('k3'), '0100ABCD00000000', p('机器二', 'x'), p('机器二', 'mac_mini.tsv'))   # 来源换个先后：P(C,D) 先于 P(A,B) 出现
    ck('来源先后与 P 行先后都换 → 配对 / 输出类型变体 / 采样模拟三张表逐字节相同（seen 按首用序，R1 / R3 排到 S A 前面）',
       r.returncode == 0 and all(k3[t] == k1[t] for t in ('pairs', 'fout_want', 'se_want')) and data(k3['seen'])[:2] == [R1, R3])
    # 产出等价：同一组来源，旧流程（消费者直读来源）与新流程（消费者读快照）
    srcs = [p('m1', 'a.tsv'), p('m1', 'dev')]
    run(os.path.join(D, 'fout_want.py'), p('old_fout.tsv'), *srcs)
    ck('fout_want.py 直读来源 = 快照 fout_want.tsv 逐字节', open(p('old_fout.tsv'), 'rb').read() == k1['fout_want'])
    open(p('union.tsv'), 'w').write(''.join(k + '\n' for k in (A, B, C, DK)))
    run(os.path.join(D, 'se_want.py'), p('old_se.tsv'), p('union.tsv'), *srcs); r = run(os.path.join(D, 'se_want.py'), p('new_se.tsv'), p('union.tsv'), '--keys', p('k1', 'se_want.tsv'))
    ck(f'se_want.py 直读来源 = se_want.py --keys 快照 逐字节（{r.stdout.strip()}）', open(p('old_se.tsv'), 'rb').read() == open(p('new_se.tsv'), 'rb').read() and data(open(p('new_se.tsv'), 'rb').read()) == [DK])
    open(p('keys.tsv'), 'w').write(''.join(k + '\n' for k in (A, B, C))); open(p('map.tsv'), 'w').write('# x\n'); sk = str(L['skey_size'])
    run(os.path.join(D, 'pso_seed.py'), p('old_pso.tsv'), p('keys.tsv'), p('map.tsv'), sk, *srcs); run(os.path.join(D, 'pso_seed.py'), p('new_pso.tsv'), p('keys.tsv'), p('map.tsv'), sk, p('k1', 'seen.tsv'))
    po, pn = (open(p(f), 'rb').read() for f in ('old_pso.tsv', 'new_pso.tsv'))
    ck(f'pso_seed.py 直读来源 = 读快照 seen.tsv 逐字节（S A / R1 / R2，R3 片元 D 不在库键里滤掉：{len(data(pn))} 行）', po == pn and data(pn) == [f'S\t{A}_b\t0', R1, R2])
    for f in ('old_pairs.tsv', 'new_pairs.tsv'): open(p(f), 'w').write(f'# 头\n{A}\t{B}\n')
    run(os.path.join(D, 'run_pairs.py'), p('old_pairs.tsv'), p('union.tsv'), *srcs); run(os.path.join(D, 'run_pairs.py'), p('new_pairs.tsv'), p('union.tsv'), p('k1', 'pairs.tsv'))
    ck('run_pairs.py 直读来源与读快照 pairs.tsv 并出的配对表：行集合相同（A→B 已有、C→D 新并入）', sorted(open(p('old_pairs.tsv')).readlines()) == sorted(open(p('new_pairs.tsv')).readlines()) == sorted(['# 头\n', f'{A}\t{B}\n', f'{C}\t{DK}\n']))
    # 程序号与缺省来源
    os.makedirs(p('root', 'exefs')); npdm = bytearray(0x100); npdm[:4] = b'META'; npdm[0x70:0x74] = struct.pack('<I', 0x80); npdm[0x80:0x84] = b'ACI0'; npdm[0x90:0x98] = struct.pack('<Q', 0x0100ABCD00000000)
    open(p('root', 'exefs', 'main.npdm'), 'wb').write(bytes(npdm))
    os.makedirs(p('run', 's2arm', 'pso_seed', '0100ABCD00000000')); shutil.copy(p('m1', 'a.tsv'), p('run', 's2arm', 'pso_seed', '0100ABCD00000000', 'job.tsv'))
    shutil.copytree(p('m1', 'dev'), p('run', 's2arm', 'pso_seed', '0100ABCD00000000', 'dev'))   # 子目录不读（来源目录只列一层 .tsv）
    env = {k: v for k, v in os.environ.items() if k != 'S2A_PSO_SOURCES'}; env['S2A_RUN_ROOT'] = p('run')
    r, k4 = snap(p('k4'), p('root'), env=env)
    ck(f'产物根没有 unpack.tsv → 读 main.npdm 程序号 0100ABCD00000000、缺省来源 <运行根>/s2arm/pso_seed/<程序号>（{r.stdout.strip()[:60]}）', r.returncode == 0 and '来源 1 份' in r.stdout and data(k4['pairs']) == [f'P\t{A}\t{B}'])
    open(p('root', 'unpack.tsv'), 'w').write('title_id\t0100ffff00000000\n'); os.makedirs(p('run', 's2arm', 'pso_seed', '0100FFFF00000000'))
    r, k5 = snap(p('k5'), p('root'), env=env)
    ck('有 unpack.tsv → 取它的 title_id（大写）定来源目录（空目录：0 份）', r.returncode == 0 and '来源 0 份' in r.stdout)
    r, k6 = snap(p('k6'), p('root'), env=dict(env, S2A_PSO_SOURCES=p('m1', 'a.tsv') + ':' + p('m1', 'dev')))
    ck('S2A_PSO_SOURCES（冒号分隔）盖过缺省来源 → 与显式给来源逐字节同', r.returncode == 0 and k6 == k1)
    r, k7 = snap(p('k7'), 'x', p('没有'))
    ck('反证：没有任何来源 → 四张表只有表头', r.returncode == 0 and all(data(k7[t]) == [] for t in TABLES))
# vk_spv（11-05，Vulkan 款出包不起局：设备首遇现编存下的游戏 SPIR-V 经快照翻进下一包离线库）。来源目录 v1/ 的 vk_spv/：A（文件名不对）、A 的同内容副本、
#   不是 SPIR-V 的 x.spv、长度不是 4 的倍数的 y.spv；来源文件 v2/a.tsv 旁的 vk_spv/：B、A 再一份。期望：快照 vk_spv/ 恰好 <键(A)>.spv、<键(B)>.spv（键 = sha256 前 16 位，同 hle_vk），
#   内容逐字节同；汇总行「Vulkan 现编 SPIR-V 2」；反证：来源都没有 vk_spv/ → 快照里没有 vk_spv/ 目录
import hashlib as _h
with tempfile.TemporaryDirectory() as t2:
    q = lambda *a: os.path.join(t2, *a)
    SA = b'\x03\x02\x23\x07' + bytes(range(16)) * 2; SB = b'\x03\x02\x23\x07' + b'\x01\x00\x00\x00' * 9
    os.makedirs(q('v1', 'vk_spv')); os.makedirs(q('v2', 'vk_spv'))
    for n_, b_ in (('wrong.spv', SA), ('dup.spv', SA), ('x.spv', b'not spirv bytes!'), ('y.spv', SA + b'\0')): open(q('v1', 'vk_spv', n_), 'wb').write(b_)
    for n_, b_ in (('b.spv', SB), ('a2.spv', SA)): open(q('v2', 'vk_spv', n_), 'wb').write(b_)
    open(q('v2', 'a.tsv'), 'w').write('')
    r = subprocess.run([sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'run_knowledge.py'), q('out'), '0100abcd00000000', q('v1'), q('v2', 'a.tsv')], capture_output=True, text=True)
    want = {_h.sha256(SA).hexdigest()[:16] + '.spv': SA, _h.sha256(SB).hexdigest()[:16] + '.spv': SB}
    got = {f: open(q('out', 'vk_spv', f), 'rb').read() for f in os.listdir(q('out', 'vk_spv'))} if os.path.isdir(q('out', 'vk_spv')) else {}
    ck(f'vk_spv：按内容重算键去重、跳过非 SPIR-V，来源是文件取旁边的 vk_spv/（{sorted(got)}）', r.returncode == 0 and got == want and 'Vulkan 现编 SPIR-V 2' in r.stdout)
    r = subprocess.run([sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'run_knowledge.py'), q('out2'), '0100abcd00000000', q('没有')], capture_output=True, text=True)
    ck('vk_spv 反证：来源都没有 vk_spv/ → 快照里没有 vk_spv/', r.returncode == 0 and not os.path.exists(q('out2', 'vk_spv')))
print(f't_run_knowledge：{n} 项，失败 {bad}')
sys.exit(1 if bad else 0)
