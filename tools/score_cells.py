#!/usr/bin/env python3
# 记分板五格（方案第 1 节；底本旧库 tools/accept_cells.py @fd68358）：score_cells.py <局目录> --game=<款> --commit=<包提交>
#     [--route=<路线提交>] [--truth=<画幅线真值表>] [--pkg_s=<出包秒数>] [--board=<记分板>] [--diag=1]
# 局目录 = tools/dev_run.sh 的 out_*。标记口径见 tests/真机契约.md。每格 绿 / 红 / 未测，读数进「读数」列，说明打到标准错误。
# 局无效（infra）：机上资源包缺文件 / 设备通道挂死 / 执行器 RESULT=push|install|lock —— 六格写「—」、读数列以【局无效】开头，board.py 不认
#   能玩：MARK + 崩 0 + 执行器没判红（满屏红除外）+ 宿主报红 0 + 有声（峰值 > 0；没有读数 = 未测）
#   画面：满屏（宿主打了「[画] 满屏判据 已开」且没有「【红】出图未满屏」）+ 画幅线真值（--truth 表里该款各检查点「总判」全「过」）；两项都绿才绿
#   帧率：MARK 后窗口 ≥ 55 秒墙钟，平均帧率 ≥ 游戏自己要的帧率 × 99%，慢帧（> 1.5 倍预算）≤ 1%。目标帧率取 host.log「帧节拍」行（tools/game_fps.py，10-21 jhz：按游戏请求的交换间隔，零配置不查表）；
#         取不到帧节拍行 / 帧率被测试封顶（S2A_FPS）/ host.log 只有控制台流 → 局无效（fps_basis），不写格
#   能耗：同一窗口整机功率（pwh.plist → pw1.plist）≤ 门槛：游戏要 60 帧（帧节拍 ≥ 59）≤ 4.8 W，其余 ≤ 3.7 W（jhz 10-26 14:1x 放宽 60 帧线）
#   首局：任一局（不分冷热，10-24 jhz「不管凉机还是热机，过了就行」）到 MARK，起局到收局我方开销造成的 > 100 ms 帧 = 0、shader_miss 合计 = 0（没有这一列 = 未测）、pso_n 合计 = 0、首遇特化慢 0
# 另记「分配」列（每帧分配闸门 frame_gate.py 的结论），不是五格之一但是硬门。
# --diag=1（带额外起局环境的局）：只打印，不写记分板。
import csv, json, glob, os, plistlib, re, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from frame_gate import judge as gate_judge
from game_fps import target as game_fps   # 游戏自己要的帧率（host.log「帧节拍」行）
import ab_span
from redline import red_lines   # 「未实现服务：」空汇总行、出图未满屏不计红

BOARD = os.path.expanduser('run/记分板.tsv')
HEAD = ['时间', '款', '包提交', '能玩', '画面', '帧率', '能耗', '首局', '分配', '读数', '局目录', '用时秒', '路线提交', '出包秒数', '模式']

def rd(o, p):
    try: return open(os.path.join(o, p), errors='replace').read()
    except OSError: return ''

def mark_draws(o):   # MARK 之后每帧绘制数的中位数；没有 MARK / 没有 draw_n 列 → None
    m = re.search(r'S2A 标记 MARK：帧 (\d+)', rd(o, 'host.log'))
    if not m or not rd(o, 'frames.tsv'): return None
    w = [int(r['draw_n']) for r in csv.DictReader(open(os.path.join(o, 'frames.tsv'), errors='replace'), delimiter='\t')
         if r.get('frame', '').isdigit() and int(r['frame']) > int(m.group(1)) and (r.get('draw_n') or '').isdigit()]
    return sorted(w)[len(w) // 2] if w else None

def scene_menu(o, game):   # 疑似菜单当成 MARK（10-21 帧率能耗线：塞尔达 botw_1021020218_1 MARK 后每帧 120 次绘制、停在菜单，整机 1.0 W 记成能耗绿）：
    #   本局 MARK 后每帧绘制中位数 < 同款其它局（调度局目录 jobs/<款>_*/out_*）各自中位数的中位数的 1/4 → 局无效；没有可比的局（新款第一局）就不判。
    #   基线取中位数：混进来的菜单局拉不低它，单局密集场景也抬不高它（10-22 旧规则取最大值、阈值一半：怪猎场景里 MARK 后中位 455–1527 随摇杆走到哪而变，
    #   04:37 真在村里的局 580 < 1527/2 被判菜单）。读数：塞尔达菜单 120 / 场景中位约 3640（30 倍）；怪猎场景最低 455 / 中位约 1300（2.9 倍）
    cur = mark_draws(o)
    if cur is None: return ''
    jobs = os.path.dirname(os.path.dirname(os.path.abspath(o))); me = os.path.realpath(o); vs = []
    for d in glob.glob(os.path.join(jobs, f'{game}_*_[12]', 'out_*')):
        if os.path.realpath(d) == me: continue
        v = mark_draws(d)
        if v: vs.append(v)
    base = sorted(vs)[len(vs) // 2] if vs else 0
    return f'疑似菜单当成 MARK（MARK 后每帧绘制中位 {cur}，不到本款基线 {base} 的 1/4）' if base and cur * 4 < base else ''

def infra(o):   # 执行器能判定的基础设施失败（不是游戏的结果）→ 局无效、不写格（10-20 总指挥：17:52 动森增量推送漏推 gal.metallib 那局曾记成能玩红）
    for l in red_lines(rd(o, 'host.log')):
        m = re.search(r'(?:读不了|打不开)\s*\S*?(资源包/\S+)', l)
        if m: return f'机上资源包缺文件（{m.group(1)[:80]}）'
    rl = rd(o, 'run.log')
    if '设备通道挂死' in rl: return '设备通道挂死'
    # 局中见过 MARK（执行器打了「窗口起点」）、收局拉回的 host.log 却是空的：拉回失败，不是游戏的结果（10-21 原生层线：d3_1021034938_1 done、host.log 0 字节、分配闸门未测）
    if '窗口起点' in rl and not rd(o, 'host.log').strip(): return '收局拉回失败（host.log 空）'
    # suspect：局中前台失焦（系统弹框挡着 App，tools/dev_run.sh）——红绿都不作数
    res = re.findall(r'^RESULT=(push|install|lock|suspect)\b.*', rd(os.path.dirname(os.path.abspath(o)), 'r.txt'), re.M)
    return f'执行器 RESULT={res[-1]}' if res else ''

def test_unready(o):   # 测试没到位（游戏没问题，是测试没把局带到位）→ 局无效、不写格（10-21 jhz：「测试的问题不能甩给开发质量」）
    hl = rd(o, 'host.log')
    # 自动玩家导航卡住没打 MARK，但游戏一直在正常出图（10-21 jhz：丝之歌 silksong_1021143210_2 卡住截图是局内可玩画面、暗黑3 d3_1021142814_2 自动玩家回退，
    #   都记成了能玩红）：代码判据——优雅收局（不是崩溃 / 提前退出）、最后 600 帧里没有 ≥ 2 秒的停帧（没卡死）、每帧绘制中位数 ≥ 50（不是黑屏 / 读盘图标）
    #   → 测试未到位、局无效；判不了的（没有逐帧表、帧太少）照旧不改判，记能玩红。真不能玩（崩溃 / 卡死 / 黑屏 / 停在读盘）照记红
    # 认自动玩家「导航卡住」结论（步数上限 / 导航时限 / 离收局不足）；出图停 / 截图卡住不算（那是游戏或显卡的事）
    if not re.search(r'自动玩家结论：没到 MARK；导航卡住（', hl): return ''
    if '优雅退出' not in hl and '收局：自动玩家结束' not in hl: return ''
    lines = [l.split('\t') for l in rd(o, 'frames.tsv').split('\n') if l.strip()]
    # 按列名取（直连 frames.tsv 列序与通用不同：host_adapt.m 只写拿得到的列）；没有 draw_n 列判不了
    head = lines[0] if lines else []; rows = lines[1:]
    if len(rows) < 600 or 'wall_us' not in head or 'draw_n' not in head: return ''
    iw, idr = head.index('wall_us'), head.index('draw_n')
    tail = rows[-601:-1]   # 末行是收局那一帧（帧时长 / 绘制不代表游戏），不算
    try: wall = [int(r[iw]) for r in tail]; draws = sorted(int(r[idr]) for r in tail)
    except (IndexError, ValueError): return ''
    med = draws[len(draws) // 2]
    if max(wall) >= 2_000_000 or med < 50: return ''
    return f'测试未到位：游戏一直在出图（最后 600 帧最长一帧 {max(wall) / 1000:.0f} ms、每帧绘制中位数 {med}、没崩溃），自动玩家导航卡住没打 MARK'

def fps_basis(o):   # 帧率口径不是「游戏自己要的原生帧率」→ 局无效、不写格（帧率 / 能耗都随帧率变）
    #   10-21 总指挥：动森 06:34（包 561d83b42 早于 fbf80e3，没有帧节拍行）按 60 判出「慢帧 100%」假红；暗黑3 05:35 执行器传 S2A_FPS=30 封了帧，1.56 W 记成能耗绿
    hl, rl = rd(o, 'host.log'), rd(o, 'run.log')
    if not hl.strip(): return ''
    if '用控制台流顶上' in rl: return 'host.log 没拉回、只有控制台流（缺帧节拍等 C# 侧行），待补拉'
    m = re.search(r'帧率上限 S2A_FPS=(\d+)', hl)
    if m: return f'帧率被测试封顶（S2A_FPS={m.group(1)}），不是游戏原生帧率'
    if not game_fps(hl)[2]: return '包里没有「帧节拍」行（早于 fbf80e3 按交换间隔出帧那版），帧率口径不同'
    return ''

MISS_MAX = 0.10   # 漏样率上限：超过即本局整机功耗无效（10-30 iOS 功耗测量口径 修法 2）

def window_power_detail(o):
    """MARK 采样窗口整机功率的全部读数 → {'w': 瓦, 'secs': 窗口秒, 'n': 样本数, 'miss': 漏样率}；读不到 → None。
    整机口径只有这一种（10-30 总指挥：量具标准「末段 100 秒、3 批中位」改为引用它）：pwh.plist → pw1.plist 的 AccumulatedSystemLoad 差 / 采样次数。
    用系统负载累计（整机耗电，不论电从电池还是充电器来），不用 AccumulatedSystemEnergyConsumed——后者充电时把充电功率也算进去
    （10-23 核：塞尔达 botw_1023201424_2 充电中，系统负载 4.11 W，与同日未充电局 3.70–4.00 W 一致；EnergyConsumed 折算 7.12 W）。
    样本约每秒一次（10-30 核：窗口 61 秒、样本 60，多局一致）：漏样率 = 1 − 样本数 / 窗口秒（run.log「收局：窗口 N 秒」）；读不到窗口秒 → miss None"""
    try:
        P = [plistlib.load(open(os.path.join(o, x), 'rb'))['IORegistry']['PowerTelemetryData'] for x in ('pwh.plist', 'pw1.plist')]
        dn = P[1]['SystemLoadAccumulatorCount'] - P[0]['SystemLoadAccumulatorCount']
        if dn <= 0: return None
        w = (P[1]['AccumulatedSystemLoad'] - P[0]['AccumulatedSystemLoad']) / dn / 1000
    except Exception: return None
    m = re.search(r'收局：窗口 (\d+) 秒', rd(o, 'run.log')); secs = int(m.group(1)) if m else None
    return {'w': w, 'secs': secs, 'n': dn, 'miss': max(0.0, 1 - dn / secs) if secs else None}

def window_power(o):
    """MARK 采样窗口整机功率（瓦，见 window_power_detail）；读不到或漏样率 > MISS_MAX（局无效）→ None"""
    d = window_power_detail(o)
    if not d or (d['miss'] is not None and d['miss'] > MISS_MAX): return None
    return d['w']

def window_power_note(o):
    """读数里跟在瓦数后面的口径说明：「窗口 61 秒、样本 60、漏样 1.6%」；漏样率超限写「…，局无效」"""
    d = window_power_detail(o)
    if not d: return ''
    if d['secs'] is None: return f'样本 {d["n"]}、窗口秒数读不到'
    return f'窗口 {d["secs"]} 秒、样本 {d["n"]}、漏样 {d["miss"] * 100:.1f}%' + (f' > {MISS_MAX * 100:.0f}%，局无效' if d['miss'] > MISS_MAX else '')

def ab_power_noise(game):
    """同包 A/B 功耗噪声底：按款查 tools/ab_noise.tsv（同包 A/A ≥ 3 局的极差，10-23 总指挥定）→ (瓦, 依据)；表里没有 → None（ab.sh 记「无噪声底，功耗不判」）"""
    p = os.environ.get('S2A_AB_NOISE_TSV') or os.path.join(os.path.dirname(os.path.abspath(__file__)), 'ab_noise.tsv')
    try:
        for l in open(p, encoding='utf-8'):
            c = l.rstrip('\n').split('\t')
            if l.startswith('#') or len(c) < 3 or c[0] != game: continue
            return float(c[1]), f'{c[2]} 局 A/A 极差（{c[3] if len(c) > 3 else ""}）'
    except OSError: pass
    return None

def max_power_noise():
    """ab_noise.tsv 里最大的噪声底（瓦）：给没有本款 A/A 数据的款判「临界」用，宁宽勿窄；表读不到 → None（不判临界）"""
    p = os.environ.get('S2A_AB_NOISE_TSV') or os.path.join(os.path.dirname(os.path.abspath(__file__)), 'ab_noise.tsv')
    try: v = [float(l.split('\t')[1]) for l in open(p, encoding='utf-8') if not l.startswith('#') and len(l.split('\t')) >= 3]
    except (OSError, ValueError): return None
    return max(v) if v else None

def fs_reds(hl):
    """【红】出图未满屏按出图时刻分两层 →（局内条数, 界面页条数）。jhz 11-02 07:2x：「游戏中能满屏就可以开满屏，菜单页、暂停页等页面满屏是另一层的问题，
    不是不能开满屏的阻塞项」——五问满屏只看 MARK 之后（游戏局内画面）的红；MARK 之前（标题 / 菜单 / 选角色 / 读盘页）的红单记「界面页未满屏」，不算满屏不过。
    红行带「第 N 次出图起」，MARK 行「S2A 标记 MARK：帧 M」（出图次数与帧号同一计数）；这局没到 MARK（判不出哪段是局内）→ 全部算局内，照旧不过"""
    #   MARK 前起的红一直没恢复、延续到 MARK 之后（同种类的「出图恢复满屏」不早于 MARK）也算局内：判据只在状态变化时记一行，起点在界面页不等于只在界面页
    #   （11-02 塞尔达 968a20ebe 回归：Mac 局第 1481 次出图起的接缝红一路没恢复、局内整幅压扁，原先只记界面页 1 条，五问满屏判过）
    mk = re.search(r'S2A 标记 MARK：帧 (\d+)', hl); m = int(mk.group(1)) if mk else None
    ing = ui = 0
    ev = re.findall(r'(【红】出图未满屏|出图恢复满屏)（([^，]*)，第 (\d+) 次出图起', hl)
    for i, (k, kind, n) in enumerate(ev):
        if k != '【红】出图未满屏': continue
        if m is None or int(n) >= m: ing += 1; continue
        rec = next((int(n2) for k2, kind2, n2 in ev[i + 1:] if k2 == '出图恢复满屏' and kind2 == kind), None)
        if rec is None or rec > m: ing += 1
        else: ui += 1
    rest = hl.count('【红】出图未满屏') - ing - ui   # 老格式红行（没有出图次数）：算局内
    return ing + rest, ui

# 出图层的原比例状态行（graphics/metal/fit_judge.h fj_judge，内容判据在真实上屏截图上看到两侧都是黑带时按种类记、种类变了才记一行）：
#   这三种 = 玩家屏上 16:9 居中、两侧黑边；其余（离开、两侧是游戏画的、游戏自己出宽图）结束一段
FS_PILLAR = ('出图原比例居中', '出图原比例回退', '出图没有可扩视野的内容')
FS_PILLAR_END = ('出图离开原比例页', '出图两侧黑是游戏画的', '出图两侧不判')

def fs_pillar(hl):
    """出图 16:9 居中留黑边的段 → [{种类, 起, 止, 截图, 盖住MARK, 局内}]。11-02 jhz 测试机2 马里奥和索尼克东京：局内比赛画面被宽屏核心认成 16:9 原比例页，
    判据按包装层的标记免判，五问记满屏过（「咱们满屏自动判据假绿还挺严重」）。原比例页 / 原比例回退 / 没有可扩视野的内容都是宿主自己的认定，玩家看到的是两侧黑边。
    起 / 止 = 出图次数（止 None = 延续到局末）；截图 = 日志里落在这段起止行之间的自动玩家截图；局内 = 延续到 MARK 之后（没到 MARK 也算，判不出前后）；
    盖住MARK = MARK 那一帧（自动玩家判定游戏画面可操控的时刻，ap_mark.png）就在这段里"""
    mk = re.search(r'S2A 标记 MARK：帧 (\d+)', hl); m = int(mk.group(1)) if mk else None
    pat = re.compile(r'(' + '|'.join(FS_PILLAR + FS_PILLAR_END) + r')[^\n]*?（第 (\d+) 次出图起）|自动玩家：截图 (\S+?)（|满屏判据第 \d+ 次留黑边段的第一帧（第 \d+ 次出图）存到 (\S+)')
    segs, cur = [], None
    for x in list(pat.finditer(hl)) + [None]:
        k, n, shot = (x.group(1), x.group(2), x.group(3) or x.group(4)) if x else ('', None, None)
        if shot:
            if cur: cur['截图'].append(os.path.basename(shot))
            continue
        if cur and (n is None or k not in FS_PILLAR or k != cur['种类']):
            cur['止'] = int(n) if n is not None else None
            cur['局内'] = m is None or cur['止'] is None or cur['止'] > m
            cur['盖住MARK'] = m is not None and cur['起'] <= m and (cur['止'] is None or cur['止'] > m)
            segs.append(cur); cur = None
        if n is not None and k in FS_PILLAR and not cur: cur = {'种类': k, '起': int(n), '止': None, '截图': []}
    return segs

def fs_tier(hl, layer=None):
    """满屏三档（11-02 总指挥）→ (档, 说明)：过 / 局内红 / 待分层 / None 判不了。开满屏只看局内，暂停页、结算页、菜单另算一层（jhz）：
    局内红 = 直连出图层比例不对、MARK 后报过【红】出图未满屏、或留黑边的段盖住 MARK 那一帧（那一帧按定义是游戏画面）；
    待分层 = 留黑边的段在 MARK 之后但没盖住 MARK、或这局没到 MARK（分不清是局内还是界面页）：不算过，也不算局内红；
    整段在 MARK 前的留黑边与 MARK 前的红归界面页，不影响档位。
    layer = {截图文件名: 局内 | 界面页}（自动分层：看图判官看段内截图，tools/quality_check.py fs_layer）：MARK 后的段里有一张局内 → 局内红；
    段内截图全判界面页 → 这段归界面页；没截图 / 没判 → 仍待分层"""
    la = re.findall(r'直连：出图层已挂到根视图 \d+x\d+ 像素（宽高比 ([0-9.]+)', hl); sc = re.search(r'iOS 壳：[^\n]*屏幕 (\d+)x(\d+) 像素', hl)
    # 屏比取 App 视图实际所在的那块屏（「视图 宽x高 点」，同宿主 ios/app.m screen_ratio）：Duo 内屏起局时 nativeBounds 仍报外屏 2034x1398（1.455），
    #   视图 951x669 点（1.422）才是玩家看到的那块屏；没有视图段的旧日志退回屏幕像素
    vw = re.search(r'iOS 壳：[^\n]*视图 (\d+)x(\d+) 点', hl)
    if la and sc:
        a = float(la[-1]); w, h = (vw.group(1), vw.group(2)) if vw else (sc.group(1), sc.group(2)); s = max(int(w), int(h)) / min(int(w), int(h))
        if abs(a / s - 1) > 0.01: return '局内红', f'直连出图层宽高比 {a:.3f}，屏比 {s:.3f}'
    ing, ui = fs_reds(hl); mk = re.search(r'S2A 标记 MARK：帧 (\d+)', hl)
    segs = [g for g in fs_pillar(hl) if g['局内']]
    desc = lambda g: f'{g["种类"]} 第 {g["起"]}–{g["止"] if g["止"] is not None else "局末"} 次出图' + (f'（截图 {",".join(g["截图"][:3])}）' if g['截图'] else '（无截图）')
    uiw = f'；界面页未满屏 {ui} 条（MARK 前，另记一层）' if ui else ''
    if ing and mk: return '局内红', f'出图报过「出图未满屏」（局内 {ing} 条）{uiw}'
    lab = lambda g: '局内' if any((layer or {}).get(x) == '局内' for x in g['截图']) else '界面页' if g['截图'] and all((layer or {}).get(x) == '界面页' for x in g['截图']) else None
    for g in segs: g['分层'] = '局内' if g['盖住MARK'] else lab(g)
    pages = [g for g in segs if g['分层'] == '界面页']; segs = [g for g in segs if g['分层'] != '界面页']
    if pages: uiw += f'；局内时段的界面页留黑边 {len(pages)} 段（看图判官判菜单 / 暂停 / 结算，另记一层）'
    hit = [g for g in segs if g['分层'] == '局内']
    if hit: return '局内红', '局内（盖住 MARK 那一帧 / 段内截图判为游戏画面）出图 16:9 居中留黑边：' + '；'.join(desc(g) for g in hit) + uiw
    if ing or segs:
        return '待分层', ('没到 MARK，分不清局内 / 界面页；' if not mk else '') + (f'出图报过「出图未满屏」{ing} 条；' if ing else '') + \
            (f'留黑边 {len(segs)} 段：' + '；'.join(desc(g) for g in segs[:4]) if segs else '') + uiw
    if '[画] 满屏判据 已开' in hl: return '过', '出图满屏判据已开、局内没报未满屏、没有 16:9 留黑边' + uiw
    if la and sc: return '过', f'直连出图层宽高比 {a:.3f}，屏比 {s:.3f}（画面判据没开）'
    return None, '判不了（没有出图层 / 屏幕尺寸行）'

def fullscreen(hl):
    """这局满屏达成没有 →（True / False / None 判不了, 说明）：fs_tier 的「过」才是 True，局内红与待分层都不是过（说明里带档位）。
    10-26 jhz「满屏是目标，不是可选项，不打开满屏测出来的帧率、耗电也没有意义」：False 时帧率 / 能耗两格记「未测」、读数标「未满屏，读数不作数」"""
    t, why = fs_tier(hl)
    return (None if t is None else t == '过'), (why if t in (None, '过') else f'{t}：{why}')

def gfx_mode(o):   # 记分板「模式」列（10-24 快速通用模式方案 §4：同一款通用局 / 直连局分开记）：host.log「图形模式：直连 / 通用」；没有这行（早于双轨的包）= 通用
    m = re.search(r'图形模式：(直连|通用)', rd(o, 'host.log')); return m.group(1) if m else '通用'

def fs_unverified(o):   # 直连局没有满屏判据（10-26 总指挥：直连上屏 nvn_mtl.m 不打「[画] 满屏判据 已开」/「【红】出图未满屏」，两行只有通用上屏 gal_core / gal_present 打）：满屏是未验，不是通过
    return gfx_mode(o) == '直连' and '[画] 满屏判据 已开' not in rd(o, 'host.log')

def frame_mark(o, mk):
    """host.log 原始 MARK 帧 → frames.tsv 取窗起帧：进程内重启过取重启后那段的 MARK，那段没有取起点行 1（tools/ab_span.py frames_mark，同统一账本「重启后段」）"""
    fm = ab_span.frames_mark(rd(o, 'host.log'))[0]
    return fm if mk is not None and fm is not None else mk


def fps_window(o, mk):
    """MARK 之后的帧间隔窗口（毫秒）→ (frames.tsv 有效行, 用的列, 窗口)。帧率格与快检的持续帧率同读这里（tools/quality_check.py metrics）"""
    rows = list(csv.DictReader(open(os.path.join(o, 'frames.tsv'), errors='replace'), delimiter='\t')) if rd(o, 'frames.tsv') else []
    rows = [r for r in rows if r.get('frame', '').isdigit() and r.get('wall_us', '').isdigit()]
    # 帧间隔：有显示层上屏间隔 disp_us（帧率能耗线，非 0）就用它；没有退回渲染线程 Present 时刻的 wall_us（带约 ±2 ms 记时抖动）
    col = 'disp_us' if rows and any((r.get('disp_us') or '0').isdigit() and int(r.get('disp_us') or 0) > 0 for r in rows) else 'wall_us'
    hf = [(int(r['frame']), int(r[col] or 0) / 1000) for r in rows if (r.get(col) or '').isdigit()]
    # MARK 后改出帧状态的段（逻辑速度同局 A/B）不进窗口；进程内重启过：frames.tsv 只剩重启后那段，段表也只取那段（tools/ab_span.py frames_mark）。
    #   起帧 mk 由调用方定：拿 host.log 原始 MARK 的调用方先过 frame_mark（下面）；统一账本自己按重启分段定好了再给
    sp = ab_span.frames_mark(rd(o, 'host.log'))[1]
    return rows, col, [w for f, w in hf if mk is not None and f > mk and ab_span.keep(f, sp)]


def cells(o, game, truth=None):
    hl, rl = rd(o, 'host.log'), rd(o, 'run.log'); fps, fpsw, fpsok = game_fps(hl); bud = 1000.0 / fps
    crash = hl.count('CRASH'); mark = re.search(r'S2A 标记 MARK：帧 (\d+)', hl); mk = int(mark.group(1)) if mark else None
    hall = red_lines(hl); hred = [l for l in hall if '自愈' not in l]; heal = len(hall) - len(hred)   # 写跟踪自愈单列、不计红（10-20 总指挥裁定，另由写跟踪 A/C 修）
    rred = red_lines(rl)
    peaks = re.findall(r'\[声\] 稳态窗口：输出峰值 ([0-9.]+)', hl); snd = float(peaks[-1]) if peaks else None
    why = f'MARK {"帧 " + str(mk) if mk else "没到"}，崩 {crash}，宿主报红 {len(hred)}（写跟踪自愈 {heal} 另计）{"，执行器判红" if rred else ""}，声音峰值 {snd if snd is not None else "—"}'
    if not mk or crash or hred or rred or (snd is not None and snd <= 0): play = '红'
    elif snd is None: play = '未测'
    else: play = '绿'
    rows, col, win = fps_window(o, frame_mark(o, mk))
    med = slow = avg = None
    if mk is None: fr, fwhy = '未测', '没到 MARK'
    # 窗口不完整（MARK 后出图停了 / 收局早）：帧率格「未测」不判红，能耗同样不判（下面 pwc）——画面停住时功耗自然低，记绿是假绿
    #   （10-21 总指挥：botw_1021152540_2「出图停在第 2686 帧已 32 秒」，读数「— ms / 慢帧 —% / 2.48 W」能耗记了绿；同类见静置局读数误报）
    elif sum(win) < 55000: fr, fwhy = '未测', f'窗口不足 55 秒：{sum(win) / 1000:.0f} 秒、{len(win)} 帧'
    else:
        med = sorted(win)[len(win) // 2]; slow = sum(w > 1.5 * bud for w in win) / len(win) * 100; avg = len(win) * 1000 / sum(win)
        fr = '绿' if fpsok and avg >= fps * 0.99 and slow <= 1 else '红'; fwhy = f'{fpsw}；{col}：平均 {avg:.2f} 帧/秒，中位 {med:.1f} ms，慢帧 {slow:.2f}%，{len(win)} 帧'
    pw = window_power(o)
    # 能耗绿 = 瓦数 ≤ 门槛（w_max：60 帧款 4.8、30 帧款 3.7）且同局帧率格绿（10-22 jhz「偏热 + 保持帧率、冷机 + 保持帧率都算过关」：降频省电但掉了帧不算成果）；瓦数达标、帧率红 → 红、读数注「帧率未保持」
    wl = w_max(fps); pwc = ('绿' if pw <= wl and fr == '绿' else '红') if pw is not None else '未测'
    fkeep = '' if pw is None or pw > wl or fr == '绿' else '，帧率未保持'
    # 充电状态 / 热档位（energy_state）只标状态、不挡判格（10-22 jhz「偏热也登记」、10-23 jhz「标清读数的当时状态就行」）：每局照判、读数标状态；
    #   看板投票最近 3 个有效局全部算，说明里列各状态局数与中位（vote）
    ewhy = energy_state(o) if pw is not None else ''
    if med is None: pwc = '未测'   # 帧时 / 慢帧没有有效窗口（没到 MARK / 窗口不完整）：能耗不判绿也不判红
    fsok, fswhy = fullscreen(hl)
    if fsok is False:   # 没满屏：帧率 / 能耗读数照记、两格不判（看板投票也不取），说明写清原因
        fr, pwc = '未测', '未测'; fwhy = f'未满屏，读数不作数（{fswhy}）；{fwhy}'
    # >100 ms 帧按渲染线程每帧 wall_us（有 gpu_us 列时与之取大），不用 disp_us：上屏间隔按 vsync 量化，同一次约 104–112 ms 的卡顿有时成 83+83（漏判）、有时成 100+100（10-20 总指挥定，原生层查实动森开局第 174–179 帧）
    big = [(v, r) for v, r in ((max(int(r.get('wall_us') or 0), int(r['gpu_us']) if (r.get('gpu_us') or '').isdigit() else 0) / 1000, r) for r in rows) if v > 100]
    # >100 ms 帧按归因分（10-22 总指挥，测试出包线拆账 19 帧）：首局格只计「我方开销」造成的，全程都算、不分 MARK 前后；游戏自己加载（渲染线程不忙、没交新帧）单列「游戏加载停顿」只作读数
    #   我方 = 当帧宏耗时（macro_us，含宏里发出的绘制处理）≥ 帧时 70%，或当帧有当场翻译 / 建管线 / 现翻着色器。着色器包种入在第 1 帧之前、帧表无逐帧信号，不在此归因
    ours = [(v, r) for v, r in big if int(r.get('macro_us') or 0) / 1000 >= 0.7 * v or any(int(r.get(k) or 0) for k in ('xlate_n', 'pso_n', 'shader_miss'))]; big_ours = [v for v, _ in ours]
    big_game = len(big) - len(big_ours)
    spec_slow = sum(1 for l in hl.split('\n') if '【首遇】管线特化慢' in l)   # 首遇延迟：管线特化单次 > 1 ms（10-21 总指挥判据）
    # 首局（10-24 jhz「首局格这种判法太过时了，不管凉机还是热机，过了就行」）：不再要冷局 + 同包热局成对、不再扣热局同位置；任一到 MARK 的局按我方归因判，
    #   看板任一局过即绿（board.vote）。>100 ms 帧只计我方开销（游戏自己读盘的「游戏加载停顿」只进读数）、现编着色器 0、现建管线 0、首遇特化慢 0
    has_miss = bool(rows) and 'shader_miss' in rows[0]; miss = sum(int(r.get('shader_miss') or 0) for r in rows) if has_miss else None
    pso = sum(int(r.get('pso_n') or 0) for r in rows) if rows and 'pso_n' in rows[0] else 0   # 没有 pso_n 列（旧包）按 0 计，有就必须 0
    first = '未测' if not mk or miss is None else '绿' if not big_ours and miss == 0 and pso == 0 and spec_slow == 0 else '红'
    first_note = f'>100 ms 我方 {len(big_ours)} 帧' + (f'（帧 {",".join(r.get("frame", "?") for _, r in ours[:8])}）' if ours else '') + f'、游戏加载停顿 {big_game}，现建管线 {pso}，首遇特化慢 {spec_slow}'
    fs_on = '[画] 满屏判据 已开' in hl; fs_red = '【红】出图未满屏' in hl or bool(fs_pillar(hl))
    fs = '红' if fs_red else '绿' if fs_on else '未测'; fsn = '未验（直连无判据）' if fs == '未测' and fs_unverified(o) else fs
    tr = '未测'
    if truth and os.path.exists(truth):
        tw = [r for r in csv.DictReader(open(truth), delimiter='\t') if r.get('游戏') == game or r.get('款') == game]
        if tw: tr = '绿' if all(r.get('总判') == '过' for r in tw) else '红'
    pic = '红' if '红' in (fs, tr) else '绿' if fs == tr == '绿' else '未测'
    gv, gwhy = gate_judge(list(csv.DictReader(open(os.path.join(o, 'frames.tsv'), errors='replace'), delimiter='\t')) if rd(o, 'frames.tsv') else [], fps, mk, gfx_mode(o) == '直连')
    f = lambda x, s: s.format(x) if x is not None else '—'
    sc = re.search(r'自检：窗口 (\S+?)（[^）]*）｜(?:可用内存 (\d+) MB|Mac 不查内存上限)', hl)   # 起局自检（原生层）：窗口整块与否 + 可用内存
    selfc = (f"自检 窗口{sc.group(1)}" + (f" 内存 {sc.group(2)} MB" if sc.group(2) else '')) if sc else '自检 —'
    sumc = lambda c: sum(int(r.get(c) or 0) for r in rows) if rows and c in rows[0] else None   # 帧率能耗线的拆账列（只记读数，不进判据）
    xl, pn, pu, sm = sumc('xlate_n'), sumc('pso_n'), sumc('pso_us'), sumc('shader_miss')
    extra = '' if sm is None and xl is None and pn is None else f" / 现翻着色器 {f(sm, '{}')} / 当场翻译程序 {f(xl, '{}')} / 现建管线 {f(pn, '{}')}（{f(pu / 1000 if pu is not None else None, '{:.0f}')} ms）"
    # 「平均 x 帧/秒（要 N）」进读数：记分板按同包近 3 局的中位数判帧率格要用它（vote）
    reading = f"{f(med, '{:.1f}')} ms / 慢帧 {f(slow, '{:.2f}')}% / {f(pw, '{:.2f}')} W{('（' + ewhy + fkeep + '）') if pw is not None else ''} / >100ms {len(big)}（我方 {len(big_ours)}、游戏加载停顿 {big_game}）/ 首遇特化慢 {spec_slow} / 报红 {len(hred)} / {selfc}{extra}" + (f" / 平均 {avg:.2f} 帧/秒（要 {fps}）" if avg is not None else '')
    if fsok is False: reading = f'【未满屏，读数不作数：{fswhy}】 / {reading}'
    notes = {'能玩': why, '画面': f'满屏 {fsn}，真值 {tr}', '帧率': fwhy, '能耗': ('未满屏，读数不作数；' if fsok is False else '') +(f'{pw:.2f} W' + ('（帧率窗口不完整，不判）' if med is None else f'（{ewhy}{fkeep}）') + f'；{window_power_note(o)}') if pw is not None else (window_power_note(o) or '读不到窗口功率'), '首局': first_note + '，现翻着色器 ' + (str(miss) if miss is not None else '无此列'), '分配': gwhy}
    return {'能玩': play, '画面': pic, '帧率': fr, '能耗': pwc, '首局': first, '分配': gv}, reading, notes

W_MAX = 3.7    # 能耗格门槛（瓦）：30 帧款
W_MAX60 = 4.8  # 60 帧款（jhz 10-26 14:1x：60 帧下整机 ≤ 4.8 W）
def w_max(fps):   # 按游戏自己要的帧率选门槛（cells 用帧节拍行；vote 用读数里的「（要 N）」，读数没有就按 30 帧门槛，不放宽旧行）
    return W_MAX60 if fps and float(fps) >= 59 else W_MAX
def _med(xs): xs = sorted(xs); n = len(xs); return xs[n // 2] if n % 2 else (xs[n // 2 - 1] + xs[n // 2]) / 2

THERMAL = ('nominal', 'fair', 'serious', 'critical')
def energy_state(o):
    """能耗读数的当时状态（10-23 jhz：「在充电 / 充电状态下充满电 / 未充电 / 热机 / 冷机等情况的能耗读数都可以作为依据，标清读数的当时状态就行，没必要教条」）：
    返回「充电状态·热档位」，例「未充电·nominal」「充电中·fair」「充满·nominal」。只标状态、不挡判格、不挡投票。
    充电状态取 MARK 采样窗口两端功率采样（pwh.plist → pw1.plist）：任一端 FullyCharged → 充满；否则任一端 IsCharging → 充电中；
    否则任一端 ExternalConnected → 外接供电（10-30 iOS 功耗测量口径：接着电源、电池不充不放，2.5–5.9 W 从适配器进来，原先误标「未充电」）；
    都不是 → 未充电；读不到 → 充电未知。
    热档位取窗口（run.log「窗口起点…第 N 帧」到「收局：窗口 … M 帧」）里 App 心跳热状态最高值（含窗口起点前最后一次）；读不到 → 热状态未知"""
    rl = rd(o, 'run.log'); hl = rd(o, 'host.log')
    ch = []
    for x in ('pwh.plist', 'pw1.plist'):
        try: io = plistlib.load(open(os.path.join(o, x), 'rb'))['IORegistry']; ch.append((io.get('IsCharging'), io.get('FullyCharged'), io.get('ExternalConnected')))
        except Exception: ch.append((None, None, None))
    cs = '充满' if any(f for _, f, _ in ch) else '充电中' if any(c for c, _, _ in ch) else '充电未知' if any(c is None for c, _, _ in ch) else '外接供电' if any(e for _, _, e in ch) else '未充电'
    m0 = re.search(r'窗口起点：[^\n]*第 (\d+) 帧', rl); m1 = re.search(r'收局：窗口 \d+ 秒、(\d+) 帧', rl)
    ts = '热状态未知'
    if m0 and m1:
        a = int(m0.group(1)); b = a + int(m1.group(1))
        hb = [(int(f), int(k)) for f, k in re.findall(r'\[心跳\] 帧 (\d+)，热状态 (\d)', hl)]
        if [f for f, k in hb if a <= f <= b]:
            hi = max([k for f, k in hb if a <= f <= b] + [k for f, k in hb if f < a][-1:])
            ts = THERMAL[hi] if hi < len(THERMAL) else str(hi)
    return f'{cs}·{ts}'

def vote(rows, cells=('能玩', '画面', '帧率', '能耗', '首局', '分配'), state=None):   # state：读数状态标签（缺省 energy_state，单测传桩）
    """同一个包的被认行（记分板行，按时间先后）→ {格: (值, 局数, 说明)}。10-21 总指挥：每格取最新一条会被单局噪声翻格
    （怪猎 5dcfe4994 能耗 16:20 红 / 16:21 绿；马车8 绿、绿、红；塞尔达 3.65 / 3.92 W 来回翻）：
      帧率 / 能耗（连续读数）：最近 3 个有效局（该格判了绿 / 红的）读数取中位数再按门槛判——能耗 中位 W ≤ 门槛（w_max：读数「要 60」4.8 W，其余 3.7 W）；
        帧率 中位「平均 / 要」≥ 0.99 且中位慢帧 ≤ 1%；有局的读数里没有平均帧率（早于本口径的行）→ 按这几局的格多数
      其余格（事件）：最近 3 个有效局多数；平票（只有 2 局且一绿一红）取较新那局
      不满 3 局：值照判、说明里标「暂定」；说明带读数散布（最小–最大）"""
    out = {}
    for i, c in enumerate(cells):
        rs = [r for r in rows if r[3 + i] in ('绿', '红')]
        # 能耗：最近 3 个有效局全部投票，不按充电 / 热状态分组排除（10-23 jhz「标清读数的当时状态就行，没必要教条」）；
        #   说明里列各状态（energy_state：充电状态·热档位）几局、中位多少，给人看。候选行 = 读数有瓦数且帧率窗口有效（帧率格判了绿 / 红；
        #   早期偏热局能耗格写的「未测」，按帧率格认窗口）。有局目录的行按目录现查状态，没有目录的行记「状态未知」
        if c == '能耗':
            W = lambda r: float(re.search(r'([\d.]+) W', r[9]).group(1))
            cand = [r for r in rows if re.search(r'([\d.]+) W', r[9]) and (r[3 + i] in ('绿', '红') or r[5] in ('绿', '红'))]
            if not cand: out[c] = ('未测', 0, ''); continue
            pick = cand[-3:]; ws = [W(r) for r in pick]; n = len(ws); m = _med(ws)
            SL = lambda r: (state or energy_state)(r[10]) if len(r) > 10 and r[10].startswith('/') and os.path.isdir(r[10]) else '状态未知'
            grp = {}
            for r in pick: grp.setdefault(SL(r), []).append(W(r))
            # 同局帧率格不是绿（帧率未保持）的局当不达标样本（按无穷大进中位数）：瓦数照列，判色时不算省电（10-22 jhz）
            nf = sum(r[5] != '绿' for r in pick); me = _med([w if r[5] == '绿' else float('inf') for w, r in zip(ws, pick)])
            txt = f'中位 {m:.2f} W（{min(ws):.2f}–{max(ws):.2f}，{n} 局{"" if n >= 3 else "，暂定"}{f"，帧率未保持 {nf} 局" if nf else ""}）'
            txt += '；各状态：' + '、'.join(f'{k} {len(v)} 局 中位 {_med(v):.2f} W' for k, v in grp.items())
            # 偏热局能证明绿、不能单独证明红（10-24 总指挥：暗黑2 凉机 3.58 W，被前面连跑的两局偏热 3.82 / 3.87 W 投成红）：全部局中位超门槛时
            #   改按凉机局（nominal；状态未知的旧行按读数里记的状态）重判；没有凉机局、帧率都保持了 → 不判红，标「偏热，待凉机复测」（调度器自动排复测）
            tg = [re.search(r'帧/秒（要 ([\d.]+)）', r[9]) for r in pick]; lim = w_max(tg[-1].group(1) if tg[-1] else None)   # 同包同款，门槛按最新一局要的帧率
            if lim == W_MAX60: txt += f'；门槛 {lim} W（60 帧口径）'   # 30 帧照旧门槛不加注
            if me > lim:
                def hot(r):
                    st = SL(r); m = re.search(r' W（([^）]*)）', r[9])
                    return bool(re.search(r'·(fair|serious|critical)', st if st != '状态未知' or not m else m.group(1)))
                cool = [r for r in cand if not hot(r)][-3:]
                if cool:
                    mc = _med([W(r) if r[5] == '绿' else float('inf') for r in cool])
                    if mc <= lim: out[c] = ('绿', len(cool), txt + f'；全部中位超门槛，凉机 {len(cool)} 局中位 {_med([W(r) for r in cool]):.2f} W 为准（偏热局只能证明绿）'); continue
                elif not nf: out[c] = ('未测', n, txt + '；偏热，待凉机复测'); continue
            # 临界（10-30 iOS 功耗测量口径修法 4）：|中位 − 门槛| < 噪声底（同包 A/A 极差，ab_noise.tsv；表里没有的款取表内最大值）时不进红绿，
            #   记「未测」+「临界·需加局」（同「偏热，待凉机复测」）；塞尔达 3.65 / 3.92 W 在 3.7 门槛两边来回翻就是这种
            nz = ab_power_noise(pick[-1][1]); nf_ = nz[0] if nz else max_power_noise()
            gap = round(abs(me - lim), 3) if me != float('inf') else None   # 读数到 0.01 W：先取整再比，免得 4.00 − 3.7 = 0.2999… 把边界判成临界
            if gap is not None and nf_ and gap < nf_:
                out[c] = ('未测', n, txt + f'；临界·需加局（|中位 − 门槛| = {gap:.2f} W < 噪声底 {nf_:.2f} W{"" if nz else "，本款无噪声底、取表内最大"}）'); continue
            out[c] = ('绿' if me <= lim else '红', n, txt); continue
        if c == '首局':   # 任一局过即绿（10-24 jhz「不管凉机还是热机，过了就行」）：同包所有判了的局里有一局绿 → 绿；都红 → 红
            ng = sum(r[3 + i] == '绿' for r in rs)
            out[c] = (('绿' if ng else '红') if rs else '未测', len(rs), f'{ng}/{len(rs)} 局过（任一局过即绿）' if rs else ''); continue
        rs = rs[-3:]
        if not rs: out[c] = ('未测', 0, ''); continue
        vs = [r[3 + i] for r in rs]; ng = vs.count('绿'); n = len(rs); tag = '' if n >= 3 else '，暂定'
        maj = '绿' if ng * 2 > n else '红' if ng * 2 < n else vs[-1]
        if c == '帧率':
            av = [re.search(r'平均 ([\d.]+) 帧/秒（要 ([\d.]+)）', r[9]) for r in rs]; sl = [re.search(r'慢帧 ([\d.]+)%', r[9]) for r in rs]
            if all(av) and all(sl):
                ra = [float(a.group(1)) / float(a.group(2)) for a in av]; sw = [float(x.group(1)) for x in sl]; mr, ms = _med(ra), _med(sw)
                out[c] = ('绿' if mr >= 0.99 and ms <= 1 else '红', n, f'中位 平均/要 {mr:.3f}、慢帧 {ms:.2f}%（慢帧 {min(sw):.2f}–{max(sw):.2f}%，{n} 局{tag}）'); continue
            sw = [float(x.group(1)) for x in sl if x]
            out[c] = (maj, n, f'多数 {ng}/{n} 绿（读数没有平均帧率{"，慢帧 " + f"{min(sw):.2f}–{max(sw):.2f}%" if sw else ""}{tag}）'); continue
        out[c] = (maj, n, f'多数 {ng}/{n} 绿{tag}')
    return out

def main():
    o = sys.argv[1]; a = dict(x[2:].split('=', 1) for x in sys.argv[2:] if x.startswith('--') and '=' in x)
    c, reading, notes = cells(o, a['game'], a.get('truth'))
    bad = infra(o) or test_unready(o) or fps_basis(o) or scene_menu(o, a['game'])
    if bad: c = {k: '—' for k in c}; reading = f'【局无效】{bad} / {reading}'; notes = {'能玩': f'局无效：{bad}'}
    row = [time.strftime('%m-%d %H:%M'), a['game'], a.get('commit', '?')] + [c[k] for k in ('能玩', '画面', '帧率', '能耗', '首局', '分配')] + \
          [reading, os.path.abspath(o), rd(o, 'timing.tsv').strip().replace('\t', '/') or '—', a.get('route', '—'), a.get('pkg_s', '—'), gfx_mode(o)]
    print('\t'.join(row))
    for k, v in notes.items(): print(f'# {k} {c[k]}（{v}）', file=sys.stderr)
    if a.get('diag') == '1': print('# 诊断局：不写记分板', file=sys.stderr); return
    b = a.get('board', BOARD); os.makedirs(os.path.dirname(b), exist_ok=True)
    gi = os.path.join(os.path.dirname(b), '.gitignore')
    if not os.path.exists(gi): open(gi, 'w').write('*\n')   # 记分板等运行产物不进仓库
    new = not os.path.exists(b)
    with open(b, 'a') as fh:
        if new: fh.write('\t'.join(HEAD) + '\n')
        fh.write('\t'.join(row) + '\n')

if __name__ == '__main__': main()
