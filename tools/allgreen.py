#!/usr/bin/env python3
# 「当前款全绿」判定（底本旧库 tools/allgreen.py @e1df8d5）：allgreen.py [--board=<记分板>] [--write] [--print]
# 按（款, 包提交, 路线提交）汇总记分板：每格按同组最近 3 个有效局判（score_cells.vote：帧率 / 能耗读数中位数、事件格多数；10-21 总指挥：单局噪声不翻格），五格 + 分配闸门都绿 = 全绿。
# 首局只有冷启局出，所以一个包要普通局 + 冷启局合起来才可能全绿。
# --write：新达成全绿的追加一行「【全绿】」到记分板并记同目录 全绿.tsv（不重复）；--print：每款现行包的格况（巡检用）。
import csv, os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from score_cells import vote
from board import MAIN_MODE, mode_of   # 六格按哪种图形模式（通用 / 直连）
a = dict(x[2:].split('=', 1) for x in sys.argv[1:] if x.startswith('--') and '=' in x)
SB = a.get('board', os.path.expanduser('run/记分板.tsv')); AG = os.path.join(os.path.dirname(SB), '全绿.tsv')
CELLS = ['能玩', '画面', '帧率', '能耗', '首局', '分配']
rows = list(csv.reader(open(SB), delimiter='\t'))[1:] if os.path.exists(SB) else []
state, last, grp = {}, {}, {}
for r in rows:
    if len(r) < 13 or r[9].startswith('【全绿】') or mode_of(r) != MAIN_MODE: continue   # 全绿只按六格那种模式（board.MAIN_MODE）
    k = (r[1], r[2], r[12]); grp.setdefault(k, []).append(r); last[r[1]] = k
for k, rs in grp.items():
    state[k] = {c: v[0] for c, v in vote(rs, CELLS).items() if v[0] in ('绿', '红')}
done = {tuple(l.rstrip('\n').split('\t')[1:4]) for l in open(AG) if l.strip()} if os.path.exists(AG) else set()
if '--print' in sys.argv:
    for g, k in sorted(last.items()):
        st = state[k]; n = sum(st.get(c) == '绿' for c in CELLS)
        print(f"{'【全绿】' if n == len(CELLS) else '      '} {g:10s} 包 {k[1]:9s} 路线 {k[2]:8s} " + ' '.join(f"{c}{st.get(c, '未测')}" for c in CELLS) + f'  绿 {n}/{len(CELLS)}')
if '--write' in sys.argv:
    for k, st in state.items():
        if all(st.get(c) == '绿' for c in CELLS) and k not in done:
            now = time.strftime('%m-%d %H:%M')
            with open(SB, 'a') as f: f.write('\t'.join([now, k[0], k[1]] + ['绿'] * len(CELLS) + [f'【全绿】{k[0]} 包 {k[1]} 路线 {k[2]}', '—', '—', k[2], '—']) + '\n')
            with open(AG, 'a') as f: f.write('\t'.join([now, k[0], k[1], k[2]]) + '\n')
            print(f'【全绿】{k[0]} {k[1]}')
