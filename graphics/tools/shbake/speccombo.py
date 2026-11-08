#!/usr/bin/env python3
# 特化组合表收集器（画面·着色器线 10-22，动森首遇特化慢复发：混合组合录像没收全）：python3 graphics/tools/shbake/speccombo.py [<局目录 | host.log>…]
#   渲染器每次运行时特化记「特化组合 v1 <Metal 格式> <输出类型> <混合开 运算 源 目标 alpha 运算 源 目标> <写掩码>」（graphics/metal/gal_state.m spec_combo_note，
#   只记开混合或部分写掩码、会真编译的单附件组合）。特化代价按组合记、与程序和游戏无关（前提探针实测），所以本表全款共用：
#   扫调度作业里全部款的局（$S2A_SCHED_DIR/jobs/*/out_*/host.log），并进 $S2A_SHCOLLECT/_combos/spec_combos.tsv（去重、排序）。
#   出包 pack/stage_shaders.sh 先调本脚本，表放进每款包 shaders/spec_combos.tsv，运行时载入后在后台补预热。
import glob, os, re, sys

COL = os.environ.get('S2A_SHCOLLECT', os.path.join((os.environ.get('S2A_RUN_ROOT') or os.path.expanduser('~/.s2arm/run')), 's2arm/shcollect'))
SD = os.environ.get('S2A_SCHED_DIR', os.path.join((os.environ.get('S2A_RUN_ROOT') or os.path.expanduser('~/.s2arm/run')), 's2arm/sched'))
OUT = os.path.join(COL, '_combos', 'spec_combos.tsv')
LINE = re.compile('特化组合 (v1(?: [0-9-]+){10})'.encode('utf-8'))

logs = []
for a in sys.argv[1:]:
    logs += [a] if os.path.isfile(a) else glob.glob(os.path.join(a, 'host.log')) + glob.glob(os.path.join(a, '*', 'host.log'))
if len(sys.argv) <= 1:
    logs = glob.glob(os.path.join(SD, 'jobs', '*', 'out_*', 'host.log'))

old = set()
if os.path.exists(OUT):
    old = {l.rstrip('\n') for l in open(OUT, encoding='utf-8') if l.strip() and not l.startswith('#')}
have = set(old); seen = 0
for lg in logs:
    try: b = open(lg, 'rb').read()
    except OSError: continue
    ks = LINE.findall(b)
    if ks: seen += 1; have |= {k.decode() for k in ks}
if have != old:
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    tmp = OUT + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        f.write('# 特化组合表（speccombo.py）：全款共用，每行 v1 <Metal 格式> <输出类型> <混合 7 项> <写掩码>\n')
        for l in sorted(have): f.write(l + '\n')
    os.replace(tmp, OUT)
print(f'speccombo：扫局 {len(logs)} 个、带组合行 {seen} 个；组合表 {len(old)} → {len(have)} 条（{OUT}）')
