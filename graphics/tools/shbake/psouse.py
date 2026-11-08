#!/usr/bin/env python3
# 管线首用表收集器（画面·着色器线 10-22，马车8 换场景首帧建管线 92–125 ms 全是归档命中：开片 79 次 + 取 145 条全在渲染线程）：
#   python3 graphics/tools/shbake/psouse.py <款> [<局目录 | host.log>…]
#   渲染器每条游戏程序的管线首次建成 / 取到时记「管线首用 v1 <键字节数> <出图帧> <b|f> <函数名串> <管线键编码>」（graphics/metal/gal_state.m pf_note；b = 基础管线、f = 完整管线）。
#   本表按款收：缺省扫调度作业里该款的正式局（$S2A_SCHED_DIR/jobs/<款>_*/out_*/host.log；包名 io.s2arm-exp.* 的实验局不收——共享收集目录只收正式局），
#   并进 $S2A_SHCOLLECT/<款>/pso_use.tsv：每行「<首用帧>\t<b|f>\t<函数名串>\t<管线键编码>」，同一条（b|f + 键编码）取各局最早的帧，按帧升序；只增不减（各局各走到一部分场景）。
#   出包 pack/stage_shaders.sh 先调本脚本：pso_gen.py（S2A_PSO_USE）把表里的管线按首用先后排进最前面几片，表放进包 shaders/pso_use.tsv（运行时程序建成时后台按表预取）
import glob, os, re, sys

G = sys.argv[1]
COL = os.environ.get('S2A_SHCOLLECT', os.path.join((os.environ.get('S2A_RUN_ROOT') or os.path.expanduser('~/.s2arm/run')), 's2arm/shcollect'))
SD = os.environ.get('S2A_SCHED_DIR', os.path.join((os.environ.get('S2A_RUN_ROOT') or os.path.expanduser('~/.s2arm/run')), 's2arm/sched'))
OUT = os.path.join(COL, G, 'pso_use.tsv')
LINE = re.compile(r'管线首用 v1 \d+ (\d+) ([bf]) (s[0-9a-f]{16}[0-9a-z_,]*) ([0-9a-f-]+)\s*$'.encode('utf-8'), re.M)

def formal(jobdir):
    try: e = open(os.path.join(jobdir, 'job.env'), encoding='utf-8', errors='replace').read()
    except OSError: return False
    m = re.search(r'^BUNDLE=(.*)$', e, re.M)
    return bool(m) and not m.group(1).strip().strip("'\"").startswith('io.s2arm-exp.')

logs = []
for a in sys.argv[2:]:
    logs += [a] if os.path.isfile(a) else glob.glob(os.path.join(a, 'host.log')) + glob.glob(os.path.join(a, '*', 'host.log'))
if len(sys.argv) <= 2:
    logs = [lg for jd in glob.glob(os.path.join(SD, 'jobs', G + '_*')) if formal(jd) for lg in glob.glob(os.path.join(jd, 'out_*', 'host.log'))]

# 键 = (b|f, 键编码) → [最早帧, 函数名串]
old = {}
if os.path.exists(OUT):
    for l in open(OUT, encoding='utf-8'):
        c = l.rstrip('\n').split('\t')
        if not l.startswith('#') and len(c) == 4: old[(c[1], c[3])] = [int(c[0]), c[2]]
have = {k: list(v) for k, v in old.items()}; seen = 0
for lg in logs:
    try: b = open(lg, 'rb').read()
    except OSError: continue
    ks = LINE.findall(b)
    if ks: seen += 1
    for fr, bf, pn, enc in ks:
        k = (bf.decode(), enc.decode()); f = int(fr)
        if k not in have or f < have[k][0]: have[k] = [f, pn.decode()]
if have != old:
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    tmp = OUT + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        f.write('# 管线首用表（psouse.py）：本款各正式局每条管线最早的首用出图帧，每行 <首用帧> <b|f> <函数名串> <管线键编码>，按帧升序\n')
        for (bf, enc), (fr, pn) in sorted(have.items(), key=lambda x: (x[1][0], x[1][1], x[0])): f.write(f'{fr}\t{bf}\t{pn}\t{enc}\n')
    os.replace(tmp, OUT)
print(f'psouse：{G} 扫局 {len(logs)} 个、带管线首用行 {seen} 个；表 {len(old)} → {len(have)} 条（{OUT}）')
