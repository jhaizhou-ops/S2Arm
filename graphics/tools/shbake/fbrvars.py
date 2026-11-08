#!/usr/bin/env python3
# 读帧缓冲变体请求收集器（画面·着色器线 10-22，塞尔达主几何遍每帧约 46 次拆遍：手机程序走 load_binary、没有 SPIR-V，变体只能出包预编）：
#   python3 graphics/tools/shbake/fbrvars.py <款> [<局目录 | host.log>…]
#   渲染器在「证明从程序二进制尾段恢复、变体表里没有这个映射」时记一行「读帧缓冲变体缺 v1 <顶点键> <片元键> <ydown> <绑定:槽>…」（graphics/metal/gal_fbr.m gal_prog_fbfetch），
#   本表按款收：扫调度作业里该款的局（$S2A_SCHED_DIR/jobs/<款>_*/out_*/host.log），并进 $S2A_SHCOLLECT/<款>/fbr_vars.tsv（去重、排序；只增不减：各局各收一部分）。
#   出包 pack/stage_shaders.sh 先调本脚本，表交 shader_pack.sh → ShaderBake.cs --fbr-vars → gal_xc --fbr 改写 + 预编进离线库、写进程序二进制尾段的变体表
import glob, os, re, sys

G = sys.argv[1]
COL = os.environ.get('S2A_SHCOLLECT', os.path.join((os.environ.get('S2A_RUN_ROOT') or os.path.expanduser('~/.s2arm/run')), 's2arm/shcollect'))
SD = os.environ.get('S2A_SCHED_DIR', os.path.join((os.environ.get('S2A_RUN_ROOT') or os.path.expanduser('~/.s2arm/run')), 's2arm/sched'))
OUT = os.path.join(COL, G, 'fbr_vars.tsv')
LINE = re.compile(r'读帧缓冲变体缺 (v1 [0-9a-f]{16} [0-9a-f]{16} [01](?: \d{1,3}:[0-7]){1,8})\s*$'.encode('utf-8'), re.M)

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
        f.write('# 读帧缓冲变体请求表（fbrvars.py）：本款运行时缺的变体，每行 v1 <顶点键> <片元键> <ydown> <绑定:槽>…（gal_xc --fbr 吃）\n')
        for l in sorted(have): f.write(l + '\n')
    os.replace(tmp, OUT)
print(f'fbrvars：{G} 扫局 {len(logs)} 个、带变体缺行 {seen} 个；表 {len(old)} → {len(have)} 条（{OUT}）')
