#!/usr/bin/env python3
# Mac 健康表·出表（底本旧库 tools/nine_health_table.py @a0d0574，判法沿用、采集口径换成 tests/真机契约.md）：
#   health_table.py <基线目录> [<候选目录>] [--aa=<A/A 登记表>]
# 目录下每款一个子目录（tools/mac_health.sh 产出）：host.log、frames.tsv。窗口 = MARK 之后、最后 1500 帧。
# 每款读：渲染遍 pass_n、切遍上传 upload_n、附件读写 rw_kb、绘制 draw_n（逐帧中位）；着色器现翻 shader_miss（窗口合计）；崩 / 报红行 / 分配闸门。
# 给两个目录时逐款判「变差」，有一款变差退出码 1（合入闸门用）：
#   ① 基线到 MARK、候选没到 → 变差（末行「MARK 退：款…」供列车重跑一次防偶发）
#   ② 崩、报红行、现翻任一增加；分配闸门基线不红、候选红 → 变差（不受可比与否影响）
#   ③ 可比才比计数：两局都到 MARK 且窗口都 ≥ 300 帧（或都没到 MARK），且每帧绘制相差 ≤ 30%；否则「不可比」
#   ④ 计数列变差 = 候选 − 基线 > max(2 × A/A 波动, 地板)；地板：渲染遍 / 切遍上传 基线 × 0.1 + 2，附件读写 基线 × 0.1 + 5 MB；
#      某款某列 A/A 波动 > 基线 20% → 那列只观察不判退。A/A 登记表每行「目录A<TAB>目录B」（同一提交跑两遍），波动取各对差的最大值。
import csv, collections, math, os, re, statistics as st, subprocess, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from frame_gate import judge as gate_judge
from game_fps import target as game_fps   # 目标帧率 = 游戏自己要的（host.log「帧节拍」行；10-21 jhz，不查表）
from redline import red_lines   # 「未实现服务：」空汇总行不计红
GAMES = 'acnh mk8d d2r botw d3 witcher3 silksong mhrise octopath2 xc3'.split()   # Mac 健康表：暗黑3 留作金样回归防退步，异度神剑 3 加入（10-23）
COLS = {'pass': ('pass_n', 1), 'up': ('upload_n', 1), 'rw': ('rw_kb', 1 / 1024)}   # 列名, 换算（rw → MB/帧）
NM = {'pass': '渲染遍', 'up': '切遍上传', 'rw': '附件读写'}
FLOOR = {'pass': (0.1, 2), 'up': (0.1, 2), 'rw': (0.1, 5)}

def m(D, g):
    d = os.path.join(D, g)
    try: rows = list(csv.DictReader(open(os.path.join(d, 'frames.tsv'), errors='replace'), delimiter='\t'))
    except OSError: rows = []
    rows = [r for r in rows if str(r.get('frame') or '').isdigit()]
    hl = open(os.path.join(d, 'host.log'), errors='replace').read() if os.path.exists(os.path.join(d, 'host.log')) else ''
    if not rows and not hl.strip(): return None
    mk = re.search(r'S2A 标记 MARK：帧 (\d+)', hl); mf = int(mk.group(1)) if mk else None
    hi = int(rows[-1]['frame']) if rows else 0; lo = max(hi - 1500, mf if mf is not None else 0)
    w = [r for r in rows if int(r['frame']) > lo] or rows[-1:]
    def numbers(c, cast=float):
        values = []
        for row in w:
            try: value = cast(row.get(c))
            except (ValueError, TypeError): continue
            if math.isfinite(value): values.append(value)
        return values
    def med(c, k=1):
        values = numbers(c)
        return st.median(values) * k if values else None
    x = {k: med(c, s) for k, (c, s) in COLS.items()}
    misses = numbers('shader_miss', int)
    gate_rows = [r for r in rows if all(str(r.get(c) or '').lstrip('-').isdigit() for c in ('wall_us', 'alloc_b', 'gc0', 'gc1', 'rb_us')) and all(str(r.get(c) or '').lstrip('-').isdigit() for c in ('gc2', 'gc_pause_us', 'draw_n') if c in r)]
    x.update(draws=med('draw_n'), miss=sum(misses) if misses else None, crash=hl.count('CRASH') if hl.strip() else None,
             red=len(red_lines(hl, skip_fullscreen=False)) if hl.strip() else None, mark=mf is not None, mf=mf, win=hi - lo, last=hi,
             gate=gate_judge(gate_rows, game_fps(hl)[0], mf)[0], has=all(x[k] is not None for k in COLS),
             win_self=(re.search(r'自检：窗口 (\S+?)（', hl) or re.search(r'()', '')).group(1) or '—')   # 起局自检的窗口状态（整块 / 退路段 / 没占到）
    z = subprocess.run([sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)), 'zero_gate.py'), d], capture_output=True, text=True)   # 必须为 0 的计数（C 类：静态覆盖漏项）
    x.update(zero='红' if z.returncode == 1 else '绿' if z.returncode == 0 else '未测', zero_why=z.stdout.strip().split('：', 1)[-1][:120])
    x['observed'] = any(x[k] is not None for k in (*COLS, 'draws', 'miss')) or x['gate'] != '未测' or x['zero'] != '未测' or x['crash'] is not None and x['crash'] > 0 or x['red'] is not None and x['red'] > 0
    return x

def increased(before, after):
    return after is not None and (after > 0 if before is None else after > before)


def noise(aa):
    N = collections.defaultdict(float); n = 0
    for l in (open(aa) if aa and os.path.exists(aa) else []):
        p = l.split()
        if len(p) < 2 or l.startswith('#'): continue
        n += 1
        for g in GAMES:
            x, y = m(p[0], g), m(p[1], g)
            if x and y:
                for k in COLS:
                    if x[k] is not None and y[k] is not None: N[g, k] = max(N[g, k], abs(x[k] - y[k]))
    return N, n

def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]; opt = dict(a[2:].split('=', 1) for a in sys.argv[1:] if a.startswith('--') and '=' in a)
    A = args[0]; B = args[1] if len(args) > 1 else None
    aa = opt.get('aa', os.path.expanduser('~/.s2arm/run/s2arm/health/aa.tsv')); N, naa = noise(aa)
    rd = lambda D: open(os.path.join(D, 'commit')).read().strip() if D and os.path.exists(os.path.join(D, 'commit')) else '?'
    print(f'Mac 健康表：{rd(A)}' + (f' → {rd(B)}' if B else ''))
    print('| 款 | 渲染遍/帧 | 切遍上传 | 附件读写 MB/帧 | 绘制/帧 | 现翻/崩/报红 | 分配 | 必须为 0 | 窗口 | 判 |'); print('|---|---|---|---|---|---|---|---|---|---|')
    bad = 0; observed = False; markbad = []; f0 = lambda v: f'{v:.0f}' if v is not None else '—'
    for g in GAMES:
        a = m(A, g); b = m(B, g) if B else None
        observed = observed or bool(a and a['observed']) or bool(b and b['observed'])
        if not a and not b: continue
        if not a or (B and not b): print(f'| {g} | 缺局（{A if not a else B}） | | | | | | | | |'); bad += bool(B and (a or b)['observed']); continue
        if not B:
            print(f"| {g} | {f0(a['pass'])} | {f0(a['up'])} | {f0(a['rw'])} | {f0(a['draws'])} | {f0(a['miss'])}/{f0(a['crash'])}/{f0(a['red'])} | {a['gate']} | {a['zero']}{'：' + a['zero_why'] if a['zero'] == '红' else ''} | {a['win_self']} | MARK {'帧 ' + str(a['mf']) if a['mark'] else '没到'} |"); continue
        cells = f"| {g} | {f0(a['pass'])}→{f0(b['pass'])} | {f0(a['up'])}→{f0(b['up'])} | {f0(a['rw'])}→{f0(b['rw'])} | {f0(a['draws'])}/{f0(b['draws'])} | {f0(b['miss'])}/{f0(b['crash'])}/{f0(b['red'])} | {a['gate']}→{b['gate']} | {b['zero']}{'：' + b['zero_why'] if b['zero'] == '红' else ''} | {b['win_self']} |"
        hard = [s for s, c in (('现翻增加', increased(a['miss'], b['miss'])), ('崩增加', increased(a['crash'], b['crash'])), ('报红增加', increased(a['red'], b['red'])), ('分配闸门转红', b['gate'] == '红' and a['gate'] != '红'), ('必须为 0 转红', b['zero'] == '红' and a['zero'] != '红')) if c]
        if a['mark'] and not b['mark']:
            bad += 1; markbad.append(g); print(cells + f" **变差**（没到 MARK：基线 MARK 帧 {a['mf']}，候选末帧 {b['last']}{'；' + '、'.join(hard) if hard else ''}） |"); continue
        same = a['draws'] is not None and b['draws'] is not None and a['draws'] > 0 and abs(b['draws'] - a['draws']) <= 0.3 * a['draws']
        if not (same and a['has'] and b['has'] and ((a['mark'] and b['mark'] and min(a['win'], b['win']) >= 300) or (not a['mark'] and not b['mark']))):
            why = f"MARK {'到' if a['mark'] else '没到'}/{'到' if b['mark'] else '没到'}，窗口 {a['win']}/{b['win']} 帧，绘制/帧 {f0(a['draws'])}/{f0(b['draws'])}{'' if a['has'] and b['has'] else '，缺计数列'}"
            bad += bool(hard); print(cells + (f" **变差**（{'、'.join(hard)}；计数不可比：{why}） |" if hard else f' 不可比（{why}） |')); continue
        wk, ob = [], []
        for k, (r, c) in FLOOR.items():
            n = N[g, k]
            if n > 0.2 * max(a[k], 1): ob.append(k); continue
            if b[k] - a[k] > max(2 * n, a[k] * r + c): wk.append(k)
        worse = bool(wk or hard); bad += worse
        note = '、'.join([NM[k] for k in wk] + hard)
        print(cells + f" {'**变差**（' + note + '）' if worse else '不退'}{'（只观察：' + '、'.join(NM[k] for k in ob) + '，A/A 波动 > 20%）' if ob else ''} |")
    if markbad: print('MARK 退：' + ' '.join(markbad))
    if not bad and not observed:
        print('未测：没有可用数字读数')
        sys.exit(2)
    if B: print(f"{'🔴 ' + str(bad) + ' 款变差' if bad else '🟢 都不退'}（阈值按 {naa} 对 A/A 波动 ×2，{aa}）")
    sys.exit(1 if bad else 0)

if __name__ == '__main__': main()
