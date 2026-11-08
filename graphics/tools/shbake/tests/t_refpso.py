#!/usr/bin/env python3
# 社区管线状态 → v2 行转换器单测（graphics/tools/shbake/refpso.py）：约 1 秒，退出 0 = 全过。
# 夹具（tests/refpso/，10-22 评估生成，只留动森运行时收的 212 行涉及的阶段键对）：acnh_states.tsv.gz = 社区程序 × 我方候选（reflib_v3 的 Ryujinx 特化状态 296 行 +
#   grokbot yuzu5 管线键 704 行）、acnh_gal.idx.gz = 这些阶段键的记录标志位、acnh_spec_pipes.tsv = 动森真机局收的 212 行（期望）。
# 期望（评估逐字段对位得出、不跑被测实现推；总指挥 10-22 定为锁定值）：
#   ① 只给 yuzu5：212 行里逐字段一致 195、「有该阶段键对的输出但一行都不一致」0；② 只给 Ryujinx：一致 158、不一致 19；③ 两份合并：一致 199
#   ④ 只有 Ryujinx 给出的行标「推断=a2one」，yuzu5 给出的不标；⑤ 不认识的来源格式（yuzu 版本 18、早期可迁移 0xFFFE…）不出行、按「来源格式:版本」计数
#   ⑥ 我方透明测试与社区状态不符的候选丢掉：同一社区程序两份候选（关 / 开）只出一行
#   ⑧–⑩ 见各项（10-25：yuzu 版本 16 动态混合计数、无格式号孪生按重复跳过、yuzu 版本 10 解码）
import gzip, os, shutil, subprocess, sys, tempfile
H = os.path.dirname(os.path.dirname(os.path.abspath(__file__))); F = os.path.join(H, 'tests', 'refpso')
T = tempfile.mkdtemp(prefix='t_refpso.'); fail = 0; n = 0
def ck(ok, msg):
    global fail, n
    n += 1; print(('✓ ' if ok else '✗ ') + msg); fail += 0 if ok else 1
def unz(name):
    p = os.path.join(T, name[:-3]); open(p, 'wb').write(gzip.open(os.path.join(F, name)).read()); return p
ST, IDX = unz('acnh_states.tsv.gz'), unz('acnh_gal.idx.gz')
rows = [l for l in open(ST, encoding='utf-8') if l.strip() and not l.startswith('#')]
spec = [l.split() for l in open(os.path.join(F, 'acnh_spec_pipes.tsv'), encoding='utf-8') if l.strip() and not l.startswith('#')]
def run(tag, lines):
    i, o = os.path.join(T, f'in_{tag}.tsv'), os.path.join(T, f'out_{tag}.tsv')
    open(i, 'w', encoding='utf-8').write(''.join(lines))
    r = subprocess.run([sys.executable, os.path.join(H, 'refpso.py'), i, IDX, o], capture_output=True, text=True)
    if r.returncode: print(f'✗ {tag}：refpso 退出 {r.returncode}：{r.stderr[-400:]}'); return None, None
    full = [l.rstrip('\n') for l in open(o, encoding='utf-8')]
    return [l for l in full if l.strip() and not l.startswith('#')], [l for l in full if l.startswith('#')]
def score(out):
    got = {tuple(l.split('#')[0].split()) for l in out}; pairs = {(t[1][:17], t[2]) for t in got}
    m = sum(1 for s in spec if tuple(s) in got); d = sum(1 for s in spec if tuple(s) not in got and (s[1][:17], s[2]) in pairs)
    return m, d
yz = [l for l in rows if l.split('\t')[3].startswith('ffff')]; ry = [l for l in rows if not l.split('\t')[3].startswith('ffff')]
ck(len(spec) == 212 and len(yz) == 704 and len(ry) == 296, f'夹具：期望 212 行、yuzu5 704 行、Ryujinx 296 行（实得 {len(spec)} / {len(yz)} / {len(ry)}）')
o1, _ = run('yuzu', yz); o2, _ = run('ryu', ry); o3, s3 = run('all', rows)
if o1 is not None: m, d = score(o1); ck((m, d) == (195, 0), f'① 只给 yuzu5：一致 195、不一致 0（实得 {m} / {d}）')
if o2 is not None: m, d = score(o2); ck((m, d) == (158, 19), f'② 只给 Ryujinx：一致 158、不一致 19（实得 {m} / {d}）')
if o3 is not None:
    m, d = score(o3); ck(m == 199, f'③ 两份合并：一致 199（实得 {m}，不一致 {d}）')
    ry_only = [l for l in o3 if '来源=ryu' in l and 'yuzu5' not in l]; yz_any = [l for l in o3 if 'yuzu5' in l]
    ck(ry_only and all('推断=a2one' in l for l in ry_only) and not any('推断=' in l for l in yz_any),
       f'④ 只有 Ryujinx 给的 {len(ry_only)} 行都标推断=a2one，yuzu5 给的 {len(yz_any)} 行不标')
# ⑤ 不认识的来源：拿一行 yuzu5 改成版本 18（0xFFFF0012）与早期可迁移（0xFFFE0005）
c = yz[0].split('\t'); bad = ['\t'.join(c[:3] + ['ffff0012'] + c[4:]), '\t'.join(c[:3] + ['fffe0005'] + c[4:])]
o5, s5 = run('unk', bad)
if o5 is not None:
    ck(not o5 and any('不认识 0xffff0012' in l and l.rstrip().endswith('1 条') for l in s5) and any('不认识 0xfffe0005' in l for l in s5),
       f'⑤ 不认识的来源格式不出行、按格式计数（输出 {len(o5)} 行；注释 {[l for l in s5 if "不认识" in l]}）')
# ⑥ 透明测试消歧：同一 yuzu5 状态配两份候选（我方透明测试关 / 开 GreaterOrEqual），社区状态是关 → 只出关的那份
off = [l for l in yz if l.split('\t')[2] == '-']
if off:
    c = off[0].split('\t'); pair = [off[0], '\t'.join(c[:2] + ['7:3f000000'] + c[3:])]
    o6, _ = run('at', pair)
    ck(o6 is not None and len(o6) == 1, f'⑥ 同一社区程序两份候选（透明测试关 / 开）只出关的那份 1 行（实得 {None if o6 is None else len(o6)}）')
# ⑧ yuzu 版本 16 动态混合（raw1 位 3）不出行、单独计数；⑨ 无格式号（S2RL 格式版本 1）的同字节孪生按重复跳过、输出与只给带格式号那行相同
c = yz[0].split('\t'); hx = bytearray(bytes.fromhex(c[5])); hx[48] |= 8
o8, s8 = run('dynb', ['\t'.join(c[:3] + ['ffff0010', '00000010', hx.hex()]) + '\n'])
if o8 is not None: ck(not o8 and any('动态混合（缓存不含混合状态）1' in l for l in s8), f'⑧ 版本 16 动态混合不出行、计 1（输出 {len(o8)} 行）')
o9a, _ = run('lab', [yz[0]]); o9b, s9 = run('twin', [yz[0], '\t'.join(c[:3] + ['00000000', '00000000'] + c[5:])])
if o9a is not None and o9b is not None: ck(o9a == o9b and any('无格式号的重复 1' in l for l in s9), f'⑨ 无格式号孪生按重复跳过（输出同只给带格式号那行：{o9a == o9b}）')
shutil.rmtree(T, ignore_errors=True)

# ⑦ 宽线（refpso.wl_line，10-24）：社区 Ryujinx 状态是线拓扑、线宽 > 1、顶点带 _wl 入口（记录位 14）→ 同出一行 s<键>_wl（拓扑 0、其余同原行）。期望手算：
#   线宽 2 + 线列表（拓扑 1）+ 位 14 → 出 ['v2', 'sAAAA_wl', 'sBBBB', '0', 原行第 4 列起]；线宽 1 → 不出；三角形（拓扑 4）→ 不出；没有位 14 → 不出；没有片元（'-'）→ 不出
import ast as _ast
_g = {}
_src = open(os.path.join(H, 'refpso.py'), encoding='utf-8').read()
for _node in _ast.parse(_src).body:
    _nm = {_node.name} if isinstance(_node, _ast.FunctionDef) else {t.id for t in getattr(_node, 'targets', []) if isinstance(t, _ast.Name)}
    if _nm & {'topo_class', 'wl_line', 'WLINE'}: exec(compile(_ast.Module([_node], []), 'refpso.py', 'exec'), _g)
_base = ['v2', 'sAAAA', 'sBBBB', '2', '1', '0', '0', '1', '0:70:15:0:0:1:0:0:1:0']
_wl = _g['wl_line']
ck(_wl(_base, 1 << 14, {'Topology': 1, 'LineWidth': 2.0}) == ['v2', 'sAAAA_wl', 'sBBBB', '0', '1', '0', '0', '1', '0:70:15:0:0:1:0:0:1:0'], '⑦a 线宽 2、线列表、带宽线入口 → 出 _wl 行（拓扑 0、其余同原行）')
ck(_wl(_base, 1 << 14, {'Topology': 1, 'LineWidth': 1.0}) is None, '⑦b 线宽 1 → 不出')
ck(_wl(_base, 1 << 14, {'Topology': 4, 'LineWidth': 2.0}) is None, '⑦c 三角形拓扑 → 不出')
ck(_wl(_base, 0, {'Topology': 1, 'LineWidth': 2.0}) is None, '⑦d 顶点没有宽线入口（位 14 不置）→ 不出')
ck(_wl(_base[:2] + ['-'] + _base[3:], 1 << 14, {'Topology': 1, 'LineWidth': 2.0}) is None, '⑦e 没有片元 → 不出')

# ⑩ yuzu 版本 10（refpso.from_yuzu10，10-25）：手拼一条状态，期望按枚举手算。颜色格式 0：Maxwell 0xd5 → GAL 序号 9（桩）→ Metal 70；
#   附件 0（偏移 72）= 掩码 0xf | 源 RGB 因子 4（SourceAlpha）<<10 | 目标 RGB 5（OneMinusSourceAlpha）<<15 | 源 A 1（One）<<20 | 目标 A 0 | 开 1<<30，方程都是 Add(0)
#   → 槽 '0:70:15:1:0:4:5:0:1:0'（Metal 掩码 15，混合 开 / Add / SourceAlpha 4 / OneMinusSourceAlpha 5 / Add / One 1 / Zero 0）；
#   raw1 = 拓扑 4（三角形，类 3）<<24 | 位 1（扩展动态状态 2：光栅化开关不进缓存 → 不丢弃、推断 disc）；raw2 = 透明测试 7（Always）<<1 → 'A'
#   反证：同一附件字放在版本 5 的偏移 24 → 版本 10 读到 0（混合关、掩码 0），出 '0:70:0:0:0:1:0:0:1:0'，与期望不同
import struct as _st
_g2 = {'struct': _st}
for _node in _ast.parse(_src).body:
    _nm = {_node.name} if isinstance(_node, _ast.FunctionDef) else {t.id for t in getattr(_node, 'targets', []) if isinstance(t, _ast.Name)}
    if _nm & {'from_yuzu10', 'head', 'topo_class', 'mtl_mask', 'MBO', 'MBF', 'YEQ', 'YFAC', 'YMSAA'}: exec(compile(_ast.Module([_node], []), 'refpso.py', 'exec'), _g2)
def _y10(raw1, raw2, att_off, dyn1=0):
    k = bytearray(984); _st.pack_into('<II', k, 0, raw1, raw2); k[8] = 0xd5
    _st.pack_into('<I', k, att_off, 0xf | 4 << 10 | 5 << 15 | 1 << 20 | 1 << 30); _st.pack_into('<I', k, 64, dyn1)
    return _g2['from_yuzu10'](bytes(48) + bytes(k), 'sAAAA', 0, 'sBBBB', {9: 70}, {0xd5: 9})
ck(_y10(4 << 24 | 2, 7 << 1, 72) == (['v2', 'sAAAA', 'sBBBB', '3', '1', '0', '0', '1', '0:70:15:1:0:4:5:0:1:0'], 'A', 'disc'), '⑩a 版本 10：附件在偏移 72，逐字段同手算，光栅化按不丢弃、标推断 disc')
ck(_y10(4 << 24 | 2, 7 << 1, 24)[0][8] == '0:70:0:0:0:1:0:0:1:0', '⑩b 反证：附件放在版本 5 的偏移 24 → 读不到（混合关、掩码 0）')
ck(_y10(4 << 24, 3 << 1, 72, 0)[0][2:8] + [_y10(4 << 24, 3 << 1, 72, 0)[1]] == ['-', '3', '1', '0', '0', '0', 4], '⑩c 扩展动态状态 2 关、动态状态 rasterize_enable（位 5）为 0 → 丢弃（片元 -、末位 0）；透明测试 3 → 4')

print(f'refpso 单测：{n} 项，失败 {fail}')
sys.exit(1 if fail else 0)
