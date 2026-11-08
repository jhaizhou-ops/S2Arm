#!/usr/bin/env python3
# 直连片元的早期深度（layout(early_fragment_tests)）照实传：NVN 控制段 +0x718 位 0 = 驱动写 3D 寄存器 EarlyZForce 的来源（同通用档 shbake EarlyZOf）。
#   S2A.Dsh JobFor 把它写进作业 early_z，dmsh_xlate QueryGraphicsState 交给 GpuGraphicsState.EarlyZForce，片元入口带 [[early_fragment_tests]]。
# 期望不跑被测实现：本脚本自己按包格式（BTCDBTCD 分隔、头 +0x28 控制段长、+0x2c 机器码长、+0x38 起机器码再控制段）读考卷片元的 +0x718 位 0。
#   ① 位为 1 的片元（各取 N 支）：MSL 片元入口带 [[early_fragment_tests]]
#   ② 位为 0 的片元：不带
#   反证：①的支数 > 0 且 ②的支数 > 0（两边都真的比到了）；旧实现写死 false，① 全红。
# 用法：t_early_z.py <dsh_cmp.dll> <libnxgal.dylib> [考卷输入目录]（缺省 ~/.s2arm/run/s2arm/gate_data/dsh/01006F8002326000，t_dsh.sh 同一份）
import collections, os, re, struct, subprocess, sys, tempfile

N = 6
dll, nxgal = sys.argv[1], sys.argv[2]
I = sys.argv[3] if len(sys.argv) > 3 else os.path.expanduser('~/.s2arm/run/s2arm/gate_data/dsh/01006F8002326000')
if not os.path.isdir(I): print(f'✗ 考卷输入不在：{I}'); sys.exit(1)
dn = os.environ.get('DOTNET') or os.path.expanduser('~/.dotnet/dotnet')

loc = {}
for line in open(os.path.join(I, 'shader_map.tsv')):
    c = line.rstrip('\n').split('\t')
    if len(c) > 4 and c[0].endswith('.bin'): loc.setdefault(c[3], (c[0], int(c[1])))
packs = {}
def records(name):
    if name not in packs:
        d = open(os.path.join(I, 'pkg', name), 'rb').read(); sep = b'BTCDBTCD'; o = []; p = d.find(sep)
        while p >= 0:
            q = d.find(sep, p + 1); q = len(d) if q < 0 else q; o.append(d[p:q]); p = q if q < len(d) else -1
        packs[name] = o
    return packs[name]

want = {0: [], 1: []}
for key, (pk, i) in sorted(loc.items()):
    if not pk.startswith('ps'): continue
    r = records(pk)[i]; nctl, ncode = struct.unpack_from('<II', r, 0x28); ctl = r[0x38 + ncode:0x38 + ncode + nctl]
    if len(ctl) <= 0x718: continue
    b = ctl[0x718] & 1
    if len(want[b]) < N: want[b].append(key)
    if len(want[0]) >= N and len(want[1]) >= N: break

fails = []
def ck(what, cond):
    print(('✓ ' if cond else '✗ ') + what)
    if not cond: fails.append(what)
ck(f'反证：考卷里位为 1 的片元找到 {len(want[1])} 支、位为 0 的 {len(want[0])} 支（各要 {N}）', len(want[1]) == N and len(want[0]) == N)

with tempfile.TemporaryDirectory() as t:
    kf = os.path.join(t, 'keys.txt'); open(kf, 'w').write('\n'.join(want[0] + want[1]) + '\n')
    out = os.path.join(t, 'out')
    p = subprocess.run([dn, dll, '--pkg', os.path.join(I, 'pkg'), '--map', os.path.join(I, 'shader_map.tsv'), '--tables', os.path.join(I, 'profile', os.path.basename(os.path.normpath(I))),
                        '--out', out, '--keys', 'file:' + kf, '--nxgal', nxgal, '-j', '2'], capture_output=True, text=True)
    def entry(key):   # 片元主入口那一行（main0 的声明）
        f = os.path.join(out, key + '_b.metal')
        if not os.path.exists(f): return None
        src = open(f).read(); m = re.search(r'\bfragment\b[^\n;{]*\bmain0\(', src)
        return src[max(0, m.start() - 80):m.end()] if m else None   # 属性可能在同一行或上一行（SPIRV-Cross 的写法）
    for b in (1, 0):
        got = {k: entry(k) for k in want[b]}
        miss = [k for k, e in got.items() if e is None]
        ck(f'{"①" if b else "②"} 位为 {b} 的 {len(got)} 支都翻出了片元入口（缺 {miss[:3]}）', not miss)
        bad = [k for k, e in got.items() if e is not None and ('early_fragment_tests' in e) != bool(b)]
        ck(f'{"①" if b else "②"} 位为 {b}：入口{"带" if b else "不带"} [[early_fragment_tests]]（不符 {len(bad)} 支：{bad[:3]}）', not bad)
    if fails and p.returncode: print('dsh_cmp 输出尾：', (p.stdout + p.stderr)[-600:])
print(f'早期深度单测：{"不通 " + str(len(fails)) + " 项" if fails else "全过"}（比了位 1 {len(want[1])} 支、位 0 {len(want[0])} 支）')
sys.exit(1 if fails else 0)
