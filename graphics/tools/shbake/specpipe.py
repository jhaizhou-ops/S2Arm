#!/usr/bin/env python3
# 特化管线表收集器（画面·着色器线 10-22，动森冷启动「预热成功还慢」：iPhone 上特化与程序不无关，改为出包按「程序 × 组合」预编完整管线）：
#   python3 graphics/tools/shbake/specpipe.py <款> [<局目录 | host.log>…]
#   渲染器每次运行时真特化 / 阻塞现建游戏程序的管线记「特化管线 v2|b2 …」（graphics/metal/gal_core.m gal_pso_note_desc 文件头有格式，全是 Metal 枚举数值；
#   v2 = 颜色定了的完整管线，b2 = 颜色留空的基础管线，含 _wl / _np 入口与运行时才出现的程序配对）。本表按款收：扫调度作业里该款的局（$S2A_SCHED_DIR/jobs/<款>_*/out_*/host.log），
#   并进 $S2A_SHCOLLECT/<款>/spec_pipes.tsv（去重、排序；只增不减：各局各收一部分）。出包 pack/stage_shaders.sh 先调本脚本，表交 pso_gen.py 出完整管线进包归档
import glob, os, re, sys

G = sys.argv[1]
COL = os.environ.get('S2A_SHCOLLECT', os.path.join((os.environ.get('S2A_RUN_ROOT') or os.path.expanduser('~/.s2arm/run')), 's2arm/shcollect'))
SD = os.environ.get('S2A_SCHED_DIR', os.path.join((os.environ.get('S2A_RUN_ROOT') or os.path.expanduser('~/.s2arm/run')), 's2arm/sched'))
OUT = os.path.join(COL, G, 'spec_pipes.tsv')
LINE = re.compile(r'特化管线 ((?:v2|b2) s[0-9a-f]{16}(?:_\w+)? (?:s[0-9a-f]{16}(?:_\w+)?|-) \d+ \d+ -?\d+ -?\d+ [01](?: \d:\d+:\d+:-?\d+(?::-?\d+){6})*)\s*$'.encode('utf-8'), re.M)

logs = []
for a in sys.argv[2:]:
    logs += [a] if os.path.isfile(a) else glob.glob(os.path.join(a, 'host.log')) + glob.glob(os.path.join(a, '*', 'host.log'))
# 不给目录时只收正式局（10-22 总指挥：共享收集目录只能由收集器从正式局里收；当天塞尔达两次因实验局产物流进共享收集目录被污染）：
#   job.env 里 BUNDLE=io.s2arm-exp.*（ipa.sh 私有产物根的实验身份，sched submit --pkg）的作业跳过；要收实验局就显式把局目录作参数给本脚本
def formal(jobdir):
    try: e = open(os.path.join(jobdir, 'job.env'), encoding='utf-8', errors='replace').read()
    except OSError: return False
    m = re.search(r'^BUNDLE=(.*)$', e, re.M)
    return bool(m) and not m.group(1).strip().strip("'\"").startswith('io.s2arm-exp.')
if len(sys.argv) <= 2:
    logs = [lg for jd in glob.glob(os.path.join(SD, 'jobs', G + '_*')) if formal(jd) for lg in glob.glob(os.path.join(jd, 'out_*', 'host.log'))]

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
        f.write('# 特化管线表（specpipe.py）：本款运行时真特化 / 现建过的管线，每行 v2|b2 <顶点> <片元|-> <拓扑类> <采样数> <a2c> <a2one> <光栅化> [<槽:格式:写掩码:混合开:运算:源:目标:alpha 运算:源:目标>…]\n')
        for l in sorted(have): f.write(l + '\n')
    os.replace(tmp, OUT)
print(f'specpipe：{G} 扫局 {len(logs)} 个、带特化管线行 {seen} 个；表 {len(old)} → {len(have)} 条（{OUT}）')
