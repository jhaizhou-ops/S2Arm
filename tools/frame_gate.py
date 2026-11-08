#!/usr/bin/env python3
# 每帧分配闸门（契约 tests/真机契约.md 第 5 节）：frame_gate.py <局目录或 frames.tsv> [--fps=<帧率>] [--mark=<帧>]
#   目标帧率缺省取游戏自己要的（host.log「帧节拍」行，tools/game_fps.py；取不到按 60）；--fps 只给单测 / 手工对照用
# 读 frames.tsv（局目录下）与 host.log（取 MARK），窗口 = MARK 之后墙钟满 60 秒的帧（动作环）。没有 MARK = 没有游玩窗口，判未测
#   （10-25 交付线审：原「没有 MARK 取全局」把读盘段的分配也算进窗口，动森直连局没到 MARK 时每帧均值 10.9 KB 判了红）。
# 判据（10-22 总指挥改：要防的是「玩的时候因为回收卡顿」，原「60 秒窗内 gen0 增量 = 0」测的是运气——每次 gen0 之间累计约 15–16 MB，
#   动森两个包到 MARK 时都累计到 15.2–15.6 MB，只看落在阈值哪一边）：
#   ① 分配速率：窗口每帧分配均值 ≤ 2048 B（60 帧款）/ 4096 B（30 帧款），超了红；
#   ② GC 停顿：可玩段（MARK 之后到收局，不只窗口）单帧 gc_pause_us（本帧 GC 停顿合计）最大值 ≤ 帧预算 25%（按游戏自己要的帧率：30 帧 8.3 ms / 60 帧 4.2 ms），超了红；
#      （10-23 总指挥定：原固定 2 ms 会让动森等 30 帧款误红，一帧 33.3 ms 里停 4–8 ms 不掉帧）
#      （10-26 总指挥定：jhz 的标准是「玩的时候不卡」——只判 MARK 之后，不分 gen0 / gen1 / gen2；MARK 之前（加载段）最长停顿单列一行、只报不判。
#        取代 10-23「整局最长」：巫师3 加载段 51 ms、可玩段 0 次被判红）
#      frames.tsv 没有 gc_pause_us 列（旧包）→ 这一条记「停顿未测」、不判；
#   第 0 帧（文件首行、wall_us = 0）是启动以来的累计（分配 / 停顿都是），不进窗口；
#   ③ 读回阻塞合计 ≤ 窗口 1%、单帧 ≤ 1 帧预算（不变）。直连局（host.log「图形模式：直连」）不判、也不要 rb_us 列：读回同步是通用渲染器才有的环节
#      （10-25 总指挥定；拿直连的每帧等待顶替会把帧节拍等待算成分配问题）。通用局缺 rb_us 仍是未测。
#   gen0 / gen1 增量与 p99 单帧值只记录、不判。不在 MARK 时强制 GC（会改变被测系统）。
# 标准输出一行：绿|红|未测<TAB>说明；退出码 0 绿 / 1 红 / 2 未测。
import csv, os, re, sys

def gc_pauses(rows, row0=None, mark=None):
    """整局 GC 停顿：((判的最长 us, 帧号), (单列不判的 gen2 次数, 最长 us, 帧号))；rows 已去掉第 0 帧（row0 = 第 0 帧，只拿来比第 1 帧的 gc2）。
    gen2 = 本帧 gc2 计数比上一帧涨。游玩中的 gen2 照判（10-23 总指挥）：帧号 > MARK，或前后 30 帧 draw_n 中位 ≥ 本局 MARK 后 draw_n 中位的 1/4（正常游玩画面）；
    MARK 前且绘制很低（读盘 / 黑屏）的单列不判。没有 MARK 时「MARK 后中位」取整局中位；没有 draw_n 列的 gen2 一律单列。
    没有 gc_pause_us 列返回 None。看板（board.py）同用这一份"""
    if not rows or 'gc_pause_us' not in rows[0]: return None
    dn = 'draw_n' in rows[0]
    if dn:
        post = sorted(int(r['draw_n'] or 0) for r in rows if mark is None or int(r['frame']) > mark) or [0]
        bar = post[len(post) // 2] / 4
    judged, g2 = [(0, '-')], []
    for i, r in enumerate(rows):
        p = int(r['gc_pause_us'] or 0); prev = rows[i - 1] if i else row0
        is2 = prev is not None and 'gc2' in r and int(r['gc2'] or 0) > int(prev.get('gc2') or 0)
        if is2 and dn and (mark is not None and int(r['frame']) > mark or sorted(int(x['draw_n'] or 0) for x in rows[max(0, i - 30):i + 31])[len(rows[max(0, i - 30):i + 31]) // 2] >= bar): is2 = False
        (g2 if is2 else judged).append((p, r['frame']))
    gz, gf = max(g2) if g2 else (0, '-')
    return max(judged), (len(g2), gz, gf)

def split0(rows):
    """去掉非数字行与第 0 帧（文件首行 wall_us = 0 是启动以来的累计）：返回 (第 0 帧或 None, 其余行)"""
    rows = [r for r in rows if r['frame'].isdigit()]
    return (rows[0], rows[1:]) if rows and int(rows[0]['wall_us'] or 0) == 0 else (None, rows)

def judge(rows, fps, mark=None, direct=False):
    need = ('frame', 'wall_us', 'alloc_b', 'gc0', 'gc1') + (() if direct else ('rb_us',))
    if not rows: return '未测', '没有逐帧记录'
    miss = [c for c in need if c not in rows[0]]
    if miss: return '未测', f'frames.tsv 缺列 {",".join(miss)}'
    if mark is None: return '未测', '没有 MARK（没有游玩窗口）'
    row0, rows = split0(rows)
    after = [r for r in rows if mark is None or int(r['frame']) > mark]; win, acc = [], 0
    for r in after:   # MARK 之后按逐帧墙钟累计取满 60 秒
        win.append(r); acc += int(r['wall_us'] or 0)
        if acc >= 60e6: break
    if len(win) < 2: return '未测', f'窗口帧数 {len(win)}（MARK {mark}）'
    base = [r for r in rows if mark is not None and int(r['frame']) <= mark]
    first = base[-1] if base else win[0]   # 计数是累计值：窗口增量 = 窗口末行 − MARK 那一帧（没有 MARK 时 − 首行）
    d0 = int(win[-1]['gc0']) - int(first['gc0']); d1 = int(win[-1]['gc1']) - int(first['gc1'])
    alloc = sum(int(r['alloc_b']) for r in win) / len(win)
    wall = sum(int(r['wall_us']) for r in win); rb = None if direct else [int(r['rb_us']) for r in win]
    bud_us = 1e6 / fps; lim = 2048 if fps >= 60 else 4096; pmx = bud_us * 0.25
    bad = []
    if alloc > lim: bad.append(f'每帧分配均值 {alloc:.0f} B > {lim} B')
    if 'gc_pause_us' in rows[0]:   # 可玩段 = MARK 之后到收局（判）；加载段 = 第 1 帧到 MARK（只报不判）
        mx = lambda rs: max(((int(r['gc_pause_us'] or 0), r['frame']) for r in rs if int(r['gc_pause_us'] or 0) > 0), key=lambda x: x[0], default=(0, '-'))   # 并列取最早一帧
        (pz, pf), (lz, lf) = mx(r for r in rows if int(r['frame']) > mark), mx(r for r in rows if int(r['frame']) <= mark)
        ps = f'GC 停顿可玩段（MARK 后）最长 {pz/1000:.2f} ms（帧 {pf}，上限 {pmx/1000:.1f} ms）；加载段（MARK 前，只报不判）最长 {lz/1000:.2f} ms（帧 {lf}）'
        if pz > pmx: bad.append(f'GC 停顿可玩段最长 {pz/1000:.2f} ms > {pmx/1000:.1f} ms（帧预算 25%，帧 {pf}）')
    else: ps = '停顿未测（frames.tsv 没有 gc_pause_us 列）'
    al = sorted(int(r['alloc_b']) for r in win); p99 = al[min(len(al) - 1, int(len(al) * 0.99))]
    if rb is not None and wall > 0 and sum(rb) > wall * 0.01: bad.append(f'读回阻塞合计 {sum(rb)/1000:.1f} ms > 窗口 1%')
    if rb is not None and max(rb) > bud_us: bad.append(f'单帧读回阻塞 {max(rb)/1000:.1f} ms > 1 帧预算')
    rs = '读回 直连无此环节、不判' if rb is None else f'读回合计 {sum(rb)/1000:.1f} ms / 最长 {max(rb)/1000:.1f} ms'
    say = (f'MARK 后 {acc/1e6:.0f} 秒 {len(win)} 帧：每帧分配均值 {alloc:.0f} B（上限 {lim}），{ps}，{rs}；'
           f'只记录（不判）gen0 +{d0}、gen1 +{d1}、p99 单帧 {p99} B')
    return ('红', '；'.join(bad) + f'（{say}）') if bad else ('绿', say)

def main():
    p = sys.argv[1]; a = dict(x[2:].split('=', 1) for x in sys.argv[2:] if x.startswith('--') and '=' in x)
    d = p if os.path.isdir(p) else os.path.dirname(p) or '.'
    f = os.path.join(p, 'frames.tsv') if os.path.isdir(p) else p
    try: rows = list(csv.DictReader(open(f, errors='replace'), delimiter='\t'))
    except OSError: rows = []
    mark = int(a['mark']) if a.get('mark') else None
    try: hl = open(os.path.join(d, 'host.log'), errors='replace').read()
    except OSError: hl = ''
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    if mark is None:   # 进程内重启过：frames.tsv 只剩重启后那段，起帧取那段的 MARK、没有取起点行 1（tools/ab_span.py frames_mark，同统一账本「重启后段」）
        from ab_span import frames_mark; mark = frames_mark(hl)[0]
    direct = '图形模式：直连' in hl
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__))); from game_fps import of_dir
    fps = float(a['fps']) if a.get('fps') else of_dir(d)[0]
    v, say = judge(rows, fps, mark, direct)
    print(f'{v}\t{say}')
    sys.exit({'绿': 0, '红': 1}.get(v, 2))

if __name__ == '__main__': main()
