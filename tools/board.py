#!/usr/bin/env python3
# 记分板 + 里程碑读数（总指挥汇报的唯一来源）：board.py [--write]
# 读：记分板 run/记分板.tsv（iPhone 局，tools/score_cells.py 写）、Mac 健康表局 ~/.s2arm/run/s2arm/health/*/<款>/host.log（tools/mac_health.sh 写）。
# 里程碑判据（方案第 7 节）：
#   M0 动森 Mac 零配置走到 MARK、报红 0          ← 最近一次有动森的健康表局
#   M1 动森 iPhone 走到 MARK、每帧托管分配闸门绿  ← 里程碑证据 milestones/M1_*/out_*/（最近一份）：host.log 有 MARK 且 frames.tsv 过分配闸门（10-20 总指挥：不读局目录，清盘会删）；
#      分配口径（10-20 总指挥定稿）：MARK 后 60 秒动作环内 gen0 / gen1 回收增量 0（frame_gate.py），窗口均值 ≤4096 B 与 p99 单帧只作辅助读数
#   M2 动森 iPhone 五格全绿                      ← 里程碑证据 milestones/M2_*/（board读数.txt 六格全绿，来源.txt 记包号）；没有归档证据时按现行包 allgreen 口径（五格 + 分配）
#   M3 九款 Mac 零配置走到 MARK                  ← 各款最近一次 Mac 正式到 MARK 的证据：~/.s2arm/run/s2arm/milestones/M3_*/<款>/（ap_summary.json marked + ap_mark.png 截图），款数 / 9
# 局无效（score_cells.infra：资源包缺文件 / 设备通道挂死 / 执行器 push|install|lock）的行不进任何格（10-20 总指挥）；九款都列，没局的写未测。
#   M4 马车8、暗黑2 全绿                          ← allgreen 口径
# 10-25 起里程碑按直连口径（docs/方案_快速通用模式.md §5，v3 全面切换）：上面 M0–M4 是通用口径，只在「历史」一行列出。
#   M5 快速通用模式覆盖：我方 10 款（Mac 健康表那 10 款）+ 至少 1 款 Vulkan、1 款 OpenGL，零配置直连 Mac 到 MARK  ← 健康表局与 milestones/M5_*/<款>/ 的 host.log：
#      「图形模式：直连」且依据不是环境变量（S2A_GFX 强制的不算零配置）、有 MARK；前端按「直连：Vulkan 款 / OpenGL 款」认，其余算 NVN。
#      画面与通用一致、画面异常自动退回是人核项：证据目录 milestones/M5_画面退回*/ 在才算达成
#   M6 真机首次启动即直连：≥3 款登记包真机局按直连判（看板直连口径）能玩绿、帧率与能耗格有读数、局的 host.log 依据是「包里带本翻译链的直连库」；
#      兜底退回可用：证据目录 milestones/M6_退回*/
#   M7 老系统：milestones/M7_*/<款>/host.log 直连到 MARK（直连 Metal 3 路径在下限系统 / 机型上）
#   M8 动森、马车8、暗黑2 六格全绿（直连口径）
# 各款各格按直连局读；一款没有直连局写「直连未测」，通用局读数单列一行只作对照。
# --write：结果写 run/里程碑.tsv（只在有变化时追加一行，带时刻）。
import csv, subprocess, glob, json, os, re, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from redline import red_lines   # 「未实现服务：」空汇总行不计红
from score_cells import infra, vote, test_unready, fs_unverified
from frame_gate import judge as gate_judge, gc_pauses, split0


def gc_line(rs):
    """② 读数（10-23 总指挥）：整局最长（游玩中的 gen2 也算）+ 读盘 / 黑屏中 gen2 单列（不判）；同包最近 3 个有局目录的局取最大"""
    best, g2, n = (0, '-', ''), (0, '-', ''), 0
    for r in [r for r in rs if r[10].startswith('/') and os.path.exists(f'{r[10]}/frames.tsv')][-3:]:
        hl = open(f'{r[10]}/host.log', errors='replace').read() if os.path.exists(f'{r[10]}/host.log') else ''
        m = re.search(r'S2A 标记 MARK：帧 (\d+)', hl); r0, fr = split0(list(csv.DictReader(open(f'{r[10]}/frames.tsv', errors='replace'), delimiter='\t')))
        gp = gc_pauses(fr, r0, int(m.group(1)) if m else None)
        if not gp: continue
        n += 1; name = os.path.basename(os.path.dirname(r[10]))
        if gp[0][0] > best[0]: best = (gp[0][0], gp[0][1], name)
        if gp[1][1] > g2[0]: g2 = (gp[1][1], gp[1][2], name)
    if not n: return ''
    return f"整局最长 {best[0]/1000:.2f} ms（帧 {best[1]}，{best[2]}）；读盘中 gen2（不判）" + (f"最长 {g2[0]/1000:.2f} ms（帧 {g2[1]}，{g2[2]}）" if g2[0] else '无') + f"（同包 {n} 局）"
GAMES = 'acnh mk8d d2r botw xc3 witcher3 silksong mhrise octopath2'.split()   # 10-23 jhz：异度神剑 3 换下暗黑3（暗黑3 只退出真机正式局与记分板，Mac 金样回归保留）
CELLS = ['能玩', '画面', '帧率', '能耗', '首局', '分配']
RUN = os.path.expanduser('run'); SB = f'{RUN}/记分板.tsv'; MS = f'{RUN}/里程碑.tsv'
HD = os.path.expanduser('~/.s2arm/run/s2arm/health'); MSD = os.environ.get('S2A_MILESTONES', os.path.expanduser('~/.s2arm/run/s2arm/milestones'))

def m3(g):   # 最近一次 Mac 正式到 MARK 的证据目录：（包提交, 目录）；没有 = None。只认 marked=true 且有 MARK 截图的（自动玩家误判过菜单，报数前核截图）
    ok = []
    for j in glob.glob(f'{MSD}/M3_*/{g}/ap_summary.json'):
        d = os.path.dirname(j)
        try: mk = json.load(open(j)).get('marked') is True
        except (OSError, ValueError): mk = False
        if mk and os.path.isfile(f'{d}/ap_mark.png'): ok.append(d)
    if not ok: return None
    d = max(ok, key=lambda x: os.path.getmtime(f'{x}/ap_summary.json'))
    try: c = open(f'{d}/读数.txt', errors='replace').readline().strip()[:9]
    except OSError: c = '?'
    return c, d

NX10 = 'acnh mk8d d2r botw d3 witcher3 silksong mhrise octopath2 xc3'.split()   # M5「我方 10 款」= Mac 健康表那 10 款（tools/health_table.py GAMES）

def direct_run(p):   # host.log → （零配置直连?, 到 MARK?, 前端 NVN / Vulkan / OpenGL）；不是直连局 = None
    try: hl = open(p, errors='replace').read()
    except OSError: return None
    m = re.search(r'图形模式：(直连|通用)（依据 ([^；）]*)', hl)
    if not m or m.group(1) != '直连': return None
    fe = re.search(r'直连：(Vulkan|OpenGL) 款', hl)
    return not m.group(2).startswith('环境变量'), bool(re.search(r'S2A 标记 MARK：帧 \d+', hl)), fe.group(1) if fe else 'NVN'

def mac_direct(g):   # 最近一次 Mac 零配置直连到 MARK 的局（健康表局 + milestones/M5_*/<款>/）：（前端, 局目录）；没有 = None
    ok = []
    for p in glob.glob(f'{HD}/*/{g}/host.log') + glob.glob(f'{MSD}/M5_*/{g}/host.log'):
        r = direct_run(p)
        if r and r[0] and r[1]: ok.append((os.path.getmtime(p), r[2], os.path.dirname(p)))
    return max(ok)[1:] if ok else None

def mac(g):   # 最近一次健康表局：（到 MARK?, 报红行数（不含写跟踪自愈）, 局目录, 自愈行数）——10-20 总指挥：自愈单列、不计入 M0，转 M1 / M2 跟踪
    c = [d for d in glob.glob(f'{HD}/*/{g}/host.log')]
    if not c: return None
    p = max(c, key=os.path.getmtime); hl = open(p, errors='replace').read()
    rl = red_lines(hl, skip_fullscreen=False); heal = sum(1 for l in rl if '自愈' in l)
    return bool(re.search(r'S2A 标记 MARK：帧 \d+', hl)), len(rl) - heal, os.path.dirname(p), heal

def job_fields(d):   # 局目录 → 作业文件里的 OWNER / ENVS / MODE（printf %q 写的，按 bash source 出的值取）；作业文件不在 → None
    j = os.path.dirname(d.rstrip('/')) + '.job'
    if not os.path.isfile(j): return None
    out = subprocess.run(['bash', '-c', '. "$1" 2>/dev/null; printf "%s\\t%s\\t%s" "${OWNER:-}" "${ENVS:-}" "${MODE:-}"', '_', j], capture_output=True, text=True).stdout.split('\t')
    return dict(zip(('OWNER', 'ENVS', 'MODE'), out + [''] * (3 - len(out))))

def owner(d):   # 局目录 …/sched/jobs/<局>/out_* → 作业文件 …/sched/jobs/<局>.job 的 OWNER（作业文件是 printf %q 写的，按 bash source 出的值取，不比原文）
    j = os.path.dirname(d.rstrip('/')) + '.job'
    if not os.path.isfile(j):   # 局目录 / 作业文件被清了：调度日志 logs/<局>.log 首行「派 测试机N：<款> <档>（<OWNER>：<说明>）」（10-20 清盘后动森各格读不到）
        lg = os.path.join(os.path.dirname(os.path.dirname(j)), 'logs', os.path.basename(j)[:-4] + '.log')
        try: m = re.search(r'派 测试机\d：\S+ \S+（([^：]+)：', open(lg, errors='replace').readline())
        except OSError: m = None
        return m.group(1) if m else ''
    return subprocess.run(['bash', '-c', '. "$1" 2>/dev/null; printf %s "${OWNER:-}"', '_', j], capture_output=True, text=True).stdout

def accepted(r):   # 认 jhz 实机判定行，和按正式口径跑的局：登记包、不带 --env（诊断开关 / 改路线都会写进 ENVS）、cold / run 模式（不是登记冒烟）
    #   10-24 总指挥定：证据成不成立取决于跑的条件、不取决于谁排的，OWNER 只用于记账 / 调度（原只认 OWNER=自动正式局，测试出包线按同口径排的
    #   动森首局冷局 acnh_1024163138_1 首局绿却进不了板，M2 一直差「首局未测」）。作业文件被清了、读不出口径 → 退回旧规则按 OWNER 认
    #   登记包 = 记分板包列是提交号；实验包（sched.sh submit --pkg）包列一律「实验:<包目录名>」，同口径跑也不进板（10-24 总指挥：画面着色器线省管线存档 A/B 的
    #   acnh 实验:pkg 局被收进板，还被当成现行包，M2 显示「里程碑后退步」）。jhz 实机判定行也只认登记包
    if r[2].startswith('实验:'): return False
    if '实机判' in r[9]: return True
    f = job_fields(r[10]) if r[10].startswith('/') else None
    if f is None: return owner(r[10]) == '自动正式局'
    # 只带 S2A_GFX=generic / direct 的不算诊断：图形模式是记分板「模式」列的维度（10-25 起不写缺省直连，兜底质量局显式写 generic），照收、按模式分开投票
    envs = re.sub(r'(^|\s)S2A_GFX=(generic|direct)(?=\s|$)', ' ', f['ENVS'])
    return not envs.strip() and f['MODE'] in ('', 'run', 'cold')

MAIN_MODE = '直连'   # 六格按直连局判（10-25 jhz「切换门槛去掉，立即全面切换」）；通用局单列一行，只记兜底质量。直连局逐帧表（性能攻坚线 direct/frames-tsv）进来前帧率格显示未测，是预期
def mode_of(r): return r[14] if len(r) > 14 and r[14] in ('直连', '通用') else '通用'   # 没有「模式」列的旧行 = 通用（早于双轨的包）

def board(mode=MAIN_MODE):   # mode：只用这种图形模式的局（同一款通用 / 直连两种局分开投票）
    rows = [r for r in csv.reader(open(SB), delimiter='\t')][1:] if os.path.exists(SB) else []
    st, last, ok, cur = {}, {}, {}, {}
    for r in rows:
        if len(r) < 13 or r[9].startswith('【全绿】') or not accepted(r) or mode_of(r) != mode: continue
        # 现行包 = 最新一条自动正式局的包，那局有效与否都算；各格只用该包的有效局（10-21 总指挥：八方2 最新几包的局全是选主角地图误判、补标局无效后，
        #   看板退回去把更早的崩溃包 7b473005f 显示成「最新包」——最新包没有有效局就照实全格未测）
        if '实机判' not in r[9]: cur[r[1]] = r[2]
        if r[9].startswith('【局无效】'): continue
        if r[10].startswith('/') and infra(r[10]): continue   # 写格时还没有 infra 判定的旧行，按局目录补判
        if r[10].startswith('/') and r[3] == '红' and test_unready(r[10]): continue   # 测试未到位按局目录补判（写格时规则还没覆盖的旧行，如流程走完后探测没过）：局无效、不进格
        ok.setdefault(r[1], []).append(r)
        # 现行包只按自动局行定：jhz 实机判定行只供画面格跨包沿用，不参与选现行包（10-21 总指挥：jhz 判暗黑2 画面那行包 1b4708a5e 被当成最新包，其余五格全成未测）
        if '实机判' not in r[9] or r[1] not in last: last[r[1]] = ((r[1], r[2], ''), r)
        if r[10].startswith('/'): last[r[1] + '#局'] = ((r[1], r[2], ''), r)   # 最新一局真机局（M1 看它的 host.log；jhz 实机判定行没有局目录）
    # 每格按「该款最新包」同包最近 3 个有效局判（score_cells.vote：帧率 / 能耗取读数中位数、事件格多数、不满 3 局暂定）
    #   10-21 总指挥：原「每格取该款最新一条被认的值（跨包）」单局噪声直接翻格，jhz 每轮看到的掉格 / 涨格大半是噪声
    for g, rs in ok.items():
        k = (g, cur.get(g, last[g][0][1]), ''); last[g] = (k, last[g][1]); v = vote([r for r in rs if r[2] == k[1]], CELLS)
        st[k] = {c: v[c][0] for c in CELLS if v[c][0] in ('绿', '红')}; st[k]['#注'] = {c: v[c] for c in CELLS}
        # 画面格例外（10-21 总指挥：同包规则让 jhz 实机判的画面一换包就清零，M2 跟着变「画面未测」，jhz 不可能每包重判）：
        #   取 jhz 最近一次实机判定（读数里有「实机判」），跨包沿用，直到 jhz 新判定、或之后有别的包的自动局画面格报红（满屏判据 / 宽屏门禁）
        #   旧包的自动红不粘住（10-22 总指挥：d3 挂着 d4c20346c 贴边暗带误报的红，判据修好后现行包局局满屏绿仍显示红）：现行包不是报红那包、
        #   现行包有自动局且都没报红 → 那次红作废，画面显示未测（满屏判据过、真值未测，交 jhz 判），不回到 jhz 早先的判定。只作废自动红盖掉的 jhz 绿；jhz 判的红只等 jhz 新判定
        jh = [i for i, r in enumerate(rs) if '实机判' in r[9] and r[4] in ('绿', '红')]
        if jh:
            j = rs[jh[-1]]; pv = j[4]; why = f'jhz 判 {j[0]} 包 {j[2]}'
            red = [r for r in rs[jh[-1] + 1:] if '实机判' not in r[9] and r[4] == '红' and r[2] != j[2]]
            if red:
                cr = [r for r in rs if r[2] == k[1] and '实机判' not in r[9]]
                if j[4] == '绿' and k[1] != red[-1][2] and cr and all(r[4] != '红' for r in cr):   # jhz 自己判的红不作废
                    pv = '未测'; why += f'；之后自动判据 {red[-1][0]} 包 {red[-1][2]} 报红，现行包 {k[1]} 的 {len(cr)} 局自动局都没报红 → 旧红作废，待 jhz 判'
                else: pv = '红'; why += f'；之后自动判据 {red[-1][0]} 包 {red[-1][2]} 报红'
            # 直连无满屏判据（10-26 总指挥：直连上屏不打满屏判据行，自动局永远报不出红，jhz 早先判的绿跨包一直挂着 = 绿着失效）：
            #   jhz 判的是别的包、现行包的自动局全是「直连且没有满屏判据」→ 不沿用 jhz 的绿，画面未测；jhz 判的就是现行包则照用
            cd = [r for r in rs if r[2] == k[1] and '实机判' not in r[9] and r[10].startswith('/')]
            if pv == '绿' and j[2] != k[1] and cd and all(fs_unverified(r[10]) for r in cd):
                pv = '未测'; why += f'；现行包 {k[1]} 的 {len(cd)} 局都是直连、没有满屏判据，jhz 的绿不跨包沿用，待直连满屏判据接通后重判'
            if pv == '未测': st[k].pop('画面', None)
            else: st[k]['画面'] = pv
            st[k]['#注']['画面'] = (pv, 0, why)
    for g, p in cur.items():   # 只有无效局的款：现行包照列、全格未测
        if g not in last: k = (g, p, ''); last[g] = (k, None); st[k] = {'#注': {c: ('未测', 0, '') for c in CELLS}}
    return st, last, ok

def main():
    st, last, ok = board(); hist = []; out = []
    OTHER = '直连' if MAIN_MODE == '通用' else '通用'; so_, lo, _ = board(OTHER)   # 另一种模式的局单列一行
    gst, glast, _ = board('通用')   # 历史 M0–M4 是通用口径
    a = mac('acnh')
    hist.append(('M0', '达成' if a and a[0] and a[1] == 0 else '未达', f'动森 Mac：{"没有健康表局" if not a else ("到 MARK" if a[0] else "没到 MARK") + f"，报红 {a[1]} 行、写跟踪自愈 {a[3]} 行另计（{a[2]}）"}'))
    ev = sorted(glob.glob(f'{MSD}/M1_*/out_*/host.log'), key=os.path.getmtime)
    if ev:
        d = os.path.dirname(ev[-1]); hl = open(ev[-1], errors='replace').read(); m = re.search(r'S2A 标记 MARK：帧 (\d+)', hl)
        fr = list(csv.DictReader(open(f'{d}/frames.tsv', errors='replace'), delimiter='\t')) if os.path.exists(f'{d}/frames.tsv') else []
        gv = gate_judge(fr, 30, int(m.group(1)) if m else None)[0]
        hist.append(('M1', '达成' if m and gv == '绿' else '未达', f'动森 iPhone 里程碑证据（{os.path.relpath(d, MSD)}）：{"到" if m else "没到"} MARK，分配 {gv}'))
    else: hist.append(('M1', '未达', f'没有 M1 里程碑证据（{MSD}/M1_*/out_*/）'))
    green = lambda g, st=gst: [k for k, s in st.items() if k[0] == g and all(s.get(c) == '绿' for c in CELLS)]
    # M2 按归档证据记达成（10-24 总指挥：里程碑是证明过的能力，同 M1 / M3，不随每个新包翻回去）：milestones/M2_*/board读数.txt 里动森那段六格全绿（「绿 6/6」）；
    #   没有归档证据才按现行包现算。现行包六格另显示，新包不全绿就标「里程碑后退步」
    cur_cells = ' '.join(f'{c}{gst[glast["acnh"][0]].get(c, "未测")}' for c in CELLS) if 'acnh' in glast else '没有局'
    ev2 = [d for d in sorted(glob.glob(f'{MSD}/M2_*/'), key=os.path.getmtime) if '绿 6/6' in (open(d + 'board读数.txt', errors='replace').read() if os.path.exists(d + 'board读数.txt') else '')]
    if ev2:
        src = open(ev2[-1] + '来源.txt', errors='replace').read() if os.path.exists(ev2[-1] + '来源.txt') else ''
        pk = re.search(r'包：(\w+)', src); now = green('acnh')
        hist.append(('M2', '达成', f'动森全绿（里程碑证据 {os.path.relpath(ev2[-1].rstrip("/"), MSD)}，包 {pk.group(1) if pk else "?"}）'
                    + ('' if now else f'；现行包 {glast["acnh"][0][1] if "acnh" in glast else "?"} 里程碑后退步：{cur_cells}')))
    else: hist.append(('M2', '达成' if green('acnh') else '未达', '动森全绿：' + (f'包 {green("acnh")[0][1]}' if green('acnh') else cur_cells)))
    ms = {g: m3(g) for g in GAMES}; n = sum(1 for v in ms.values() if v)
    hist.append(('M3', '达成' if n == 9 else '未达', f'九款 Mac 到 MARK {n}/9（证据 {MSD}/M3_*/<款>/；没到：{" ".join(g for g in GAMES if not ms[g]) or "无"}）'))
    hist.append(('M4', '达成' if green('mk8d') and green('d2r') else '未达', f'马车8 全绿 {"是" if green("mk8d") else "否"}，暗黑2 全绿 {"是" if green("d2r") else "否"}'))
    # —— 直连口径 M5–M8（docs/方案_快速通用模式.md §5）——
    md = {g: mac_direct(g) for g in NX10}; n5 = sum(1 for v in md.values() if v and v[0] == 'NVN')
    fe = {}
    for p in glob.glob(f'{MSD}/M5_*/*/host.log'):
        r = direct_run(p)
        if r and r[0] and r[1] and r[2] != 'NVN': fe.setdefault(r[2], set()).add(os.path.basename(os.path.dirname(p)))
    pic5 = bool(glob.glob(f'{MSD}/M5_画面退回*/'))
    out.append(('M5', '达成' if n5 == len(NX10) and fe.get('Vulkan') and fe.get('OpenGL') and pic5 else '未达',
                f'零配置直连 Mac 到 MARK：NVN {n5}/{len(NX10)}（没到：{" ".join(g for g in NX10 if not md[g]) or "无"}）；'
                f'Vulkan {len(fe.get("Vulkan", ()))} 款{"（" + " ".join(sorted(fe["Vulkan"])) + "）" if fe.get("Vulkan") else ""}；'
                f'OpenGL {len(fe.get("OpenGL", ()))} 款；画面一致 / 自动退回证据 {"在" if pic5 else "没有（milestones/M5_画面退回*/）"}'))
    green = lambda g: [k for k, s in st.items() if k[0] == g and all(s.get(c) == '绿' for c in CELLS)]
    first = []
    for g in GAMES:
        if g not in last: continue
        s6 = st[last[g][0]]; hl = last.get(g + '#局', (None, ['']*11))[1][10]
        boot = bool(hl) and '包里带本翻译链的直连库' in (open(os.path.join(hl, 'host.log'), errors='replace').read() if os.path.isfile(os.path.join(hl, 'host.log')) else '')
        if s6.get('能玩') == '绿' and s6.get('帧率', '未测') != '未测' and s6.get('能耗', '未测') != '未测' and boot: first.append(g)
    fb6 = bool(glob.glob(f'{MSD}/M6_退回*/'))
    out.append(('M6', '达成' if len(first) >= 3 and fb6 else '未达', f'真机首次启动即直连、能玩绿且帧率 / 能耗有读数 {len(first)}/3（{" ".join(first) or "无"}）；兜底退回证据 {"在" if fb6 else "没有（milestones/M6_退回*/）"}'))
    m7 = [p for p in glob.glob(f'{MSD}/M7_*/*/host.log') if (lambda r: r and r[1])(direct_run(p))]
    out.append(('M7', '达成' if m7 else '未达', f'老系统直连到 MARK：{", ".join(os.path.relpath(os.path.dirname(p), MSD) for p in m7) or "没有证据（milestones/M7_*/<款>/）"}'))
    out.append(('M8', '达成' if all(green(g) for g in ('acnh', 'mk8d', 'd2r')) else '未达', '六格全绿（直连口径）：' + '，'.join(f'{n} {"是" if green(g) else "否"}' for g, n in (('acnh', '动森'), ('mk8d', '马车8'), ('d2r', '暗黑2')))))
    # 磁盘（10-25 盘满事故）：同远端派活的判定（tools/disk_low.sh --all：本机 + mini / air，退出 0 = 有不足），不足的逐行报红
    dl = subprocess.run(['bash', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'disk_low.sh'), '--all'], capture_output=True, text=True)
    for ln in (dl.stdout.splitlines() if dl.returncode == 0 else []):
        print(f'🔴 {ln}：' + ('腾出空间（保留规则 tools/gc.sh）' if ln.startswith('磁盘不足') else '不往这台派活（门禁 / 自检不退回本机）'))
    print('里程碑（直连口径）：'); [print(f'  {m} {v}：{why}') for m, v, why in out]
    print('  历史（通用口径，v3 切换前）：' + '；'.join(f'{m} {v}' for m, v, _ in hist))
    print(f'记分板（各款现行包，六格按{MAIN_MODE}局；{OTHER}局单列对照）：')
    # jhz 实机局首遇现编（tools/dev_run.sh jhzplay 写的行，不进各格判定，只列最近一条；10-23 总指挥）
    jp = {}
    try:
        for r in csv.reader(open(SB, errors='replace'), delimiter='\t'):
            if len(r) > 9 and r[9].startswith('jhz 实机局'): jp[r[1]] = f'{r[0]} {r[9]}'
    except OSError: pass
    for g in GAMES:
        mm = f"Mac 直连 MARK {'是' if md.get(g) or mac_direct(g) else '否'}"
        if g in last:
            k = last[g][0]; s = st[k]; nt = s['#注']
            print(f"  {g:10s} 最新包 {k[1]:9s} " + ' '.join(f"{c}{s.get(c, '未测')}" + (f"（{nt[c][1]} 局暂定）" if 0 < nt[c][1] < 3 else '') for c in CELLS) + f"  绿 {sum(s.get(c) == '绿' for c in CELLS)}/{len(CELLS)}  {mm}")
            for c in ('画面', '帧率', '能耗'):
                if nt[c][2]: print(f"  {'':10s}   {c}：{nt[c][2]}")
            gl = gc_line([r for r in ok.get(g, []) if r[2] == k[1]])
            if gl: print(f"  {'':10s}   GC 停顿：{gl}")
            if g in jp: print(f"  {'':10s}   jhz 实机局：{jp[g]}")
            if g in lo:
                ko = lo[g][0]; so = so_[ko]; print(f"  {'':10s}   {OTHER}局（不进六格）：包 {ko[1]} " + ' '.join(f"{c}{so.get(c, '未测')}" for c in CELLS))
        else:
            print(f"  {g:10s} {MAIN_MODE}未测（没有{MAIN_MODE}真机正式局）  {mm}")
            if g in lo:
                ko = lo[g][0]; so = so_[ko]; print(f"  {'':10s}   {OTHER}局（不进六格）：包 {ko[1]} " + ' '.join(f"{c}{so.get(c, '未测')}" for c in CELLS))
    if '--write' in sys.argv:
        line = '；'.join(f'{m} {v}' for m, v, _ in out)
        prev = open(MS).read().strip().split('\n')[-1].split('\t', 1)[-1] if os.path.exists(MS) else ''
        if line != prev:
            os.makedirs(RUN, exist_ok=True); gi = f'{RUN}/.gitignore'
            if not os.path.exists(gi): open(gi, 'w').write('*\n')
            with open(MS, 'a') as f: f.write(f"{time.strftime('%m-%d %H:%M')}\t{line}\n")
            print(f'已写 {MS}')

if __name__ == '__main__': main()
