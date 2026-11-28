#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""pack/orch/oneclick_win.py 出包机道交管线种子（11-28：--patches 只交补丁索引，统一包 kind=pso 的种子落了盘却没交 S2A_PSO_SOURCES_EXTRA，
随包 pso_manifest.tsv 0 行，启动器出的玩家包约 4.7 万行）单测：python3 tests/oneclick_win_pso_seed_test.py
下载站换成替身（patches.items_for 返回两条种子 + 一条帧率补丁），真跑 patches.index_dirs / pso_write / pso_dir。期望按规则手写：
  ① 统一包有 2 份种子 → S2A_PSO_SOURCES_EXTRA = <输出>/community/community-cache/games/<程序号>/pso，日志「管线种子：统一包 2 份交种子阶段」
  ② 调用前已有来源 /already → 不覆盖，新目录接在后面
  ③ 统一包这款没有种子 → 不设，日志「管线种子：统一包这一款没有」
反证（手跑，不在本单测里）：S2A_OW=<11-28 前的 oneclick_win.py，放在仓库原位置> 跑本单测，① ② 不通"""
import importlib.util, os, sys, tempfile, types
from pathlib import Path

R = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(R)); sys.path.insert(0, str(R / 'pack/jobs'))
src = os.environ.get('S2A_OW') or str(R / 'pack/orch/oneclick_win.py')
spec = importlib.util.spec_from_file_location('ow_under_test', src); ow = importlib.util.module_from_spec(spec); spec.loader.exec_module(ow)
import patches   # noqa: E402

bad = 0
def chk(name, want, got):
    global bad
    ok = want == got; bad += not ok
    print(f'{"通" if ok else "不通"} {name}：期望 {want!r} → 真结果 {got!r}')

TID = '0100ABCD00001000'
offer = []
patches.module_bids = lambda exefs: {'main': 'ab' * 8}
patches.items_for = lambda c, gid, bid: list(offer)
class Run:
    def __init__(self, out): self.out = Path(out); self.lines = []
    def say(self, s): self.lines.append(s)

def go(items, before=None):
    offer[:] = items
    for k in ('S2A_CPATCH_DIRS', 'S2A_CPATCH', 'S2A_PSO_SOURCES_EXTRA'): os.environ.pop(k, None)
    if before: os.environ['S2A_PSO_SOURCES_EXTRA'] = before
    d = tempfile.mkdtemp(); run = Run(d); x = Path(d) / 'x'; (x / 'exefs').mkdir(parents=True)
    ow.community_patches(run, x, TID, 'ios')
    return run, Path(d) / 'community' / 'community-cache' / 'games' / TID / 'pso'

seeds = [({'kind': 'pso', 'sha256': 'a' * 64}, b'k1\n'), ({'kind': 'pso', 'sha256': 'b' * 64}, b'k2\n')]
run, want = go(seeds)
chk('① 有种子：交 S2A_PSO_SOURCES_EXTRA', str(want), os.environ.get('S2A_PSO_SOURCES_EXTRA'))
chk('① 日志报份数', True, any('管线种子：统一包 2 份交种子阶段' in l for l in run.lines))
run, want = go(seeds, before='/already')
chk('② 已有来源不覆盖、接在后面', os.pathsep.join(['/already', str(want)]), os.environ.get('S2A_PSO_SOURCES_EXTRA'))
run, want = go([])
chk('③ 没有种子：不设', None, os.environ.get('S2A_PSO_SOURCES_EXTRA'))
chk('③ 日志说没有', True, any('管线种子：统一包这一款没有' in l for l in run.lines))
sys.exit(1 if bad else 0)
