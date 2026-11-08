#!/usr/bin/env python3
# 随包 game.tsv 的宿主解析（graphics/nvn/host/game_tsv.h）与 game.py header() 对拍：全部手写档（graphics/nvn/games/*/game.tsv，10-25 起只当测试夹具）逐项比。
# 期望 = game.py header() 的换算（缺省同宿主：10-25 起 render_cond / tex_flush_upload / tex_dirty_upload / gpu_timestamps 按 Switch 真实语义；10-31 起 tex_dyn_slots 也缺省开），
#   两套独立实现互相校验。用法：game_tsv_test.py <t_game_tsv 可执行文件>
import re, subprocess, sys
from pathlib import Path

R = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(R / 'graphics/nvn/games'))
import game as G

games = sorted(G.all_games(), key=lambda g: g.id)
want = {}
for g in games:
    m = dict(re.findall(r'#define DM_GAME_(\w+) (.*)', G.header(g)))
    e = {'APP_POOL': int(m['APP_POOL'].rstrip('ul'), 0)}
    for k in ('PRESENT_DISPLAY', 'FPS_HOLD', 'VCONV_RANGE', 'RENDER_COND', 'TEX_FLUSH_UPLOAD', 'TEX_DIRTY_UPLOAD', 'TEX_DYN_SLOTS', 'GPU_TS_SEGMENT'): e[k] = int(m[k])
    e['ALPHA_FROM_RED'] = m['ALPHA_FROM_RED'].strip('"'); e['FEEDBACK_SNAP'] = m['FEEDBACK_SNAP'].strip('"'); e['ZERO_SKIP'] = m['ZERO_SKIP'].strip('"')
    want[str(g.dir / 'game.tsv')] = e
out = subprocess.run([sys.argv[1], *want], capture_output=True, text=True, check=True).stdout.splitlines()
cols = ['GOT', 'APP_POOL', 'PRESENT_DISPLAY', 'FPS_HOLD', 'RENDER_COND', 'TEX_FLUSH_UPLOAD', 'TEX_DIRTY_UPLOAD', 'TEX_DYN_SLOTS', 'GPU_TS_SEGMENT', 'VCONV_RANGE',
        'ALPHA_FROM_RED', 'FEEDBACK_SNAP', 'ZERO_SKIP', 'ERR']
bad = 0
for line in out:
    c = line.split('\t'); path = c[0]; got = dict(zip(cols, c[1:]))
    e = want[path]
    diff = [k for k in e if (int(got[k], 0) if k not in ('ALPHA_FROM_RED', 'FEEDBACK_SNAP', 'ZERO_SKIP') else got[k]) != e[k]]
    if got['GOT'] != '1' or got['ERR'] or diff:
        bad += 1; print(f'✗ {Path(path).parent.name}：{[(k, got.get(k), e.get(k)) for k in diff]} 读到={got["GOT"]} 报错={got["ERR"]!r}')
if len(out) != len(want): bad += 1; print(f'✗ 解析输出 {len(out)} 行，手写档 {len(want)} 份')
if bad: print(f'✗ t_game_tsv：与 game.py 对拍 {bad} / {len(want)} 份不符'); sys.exit(1)
print(f'  game.py 对拍：{len(want)} 份手写档 × 12 项全符')
