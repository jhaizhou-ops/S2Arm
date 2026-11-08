#!/usr/bin/env python3
"""列车退回提示用（10-28 由 train_renumber.py --overlap 拆出；续号随补丁时刻命名 + series / 改动清单 merge=union 取消）：
python3 tools/patch_overlap.py <工作树> <合并前 main 侧提交> <分支>
分支新增补丁与 main 侧新增补丁（自合并基点起）改到同一文件的，回显「0125-x.patch（a.cs）」列表（合并后整套重放套不上时点名是和谁撞）。"""
import os, subprocess, sys

SERIES = 'compat/patches/series'

def show(wt, rev, path):
    r = subprocess.run(['git', '-c', 'core.quotepath=off', '-C', wt, 'show', f'{rev}:{path}'], capture_output=True, text=True)
    return r.stdout.split('\n') if r.returncode == 0 else []

def files(wt, rev, p):   # 补丁改到的文件（+++ b/<路径>）
    return {l[6:].strip() for l in show(wt, rev, f'compat/patches/{p}') if l.startswith('+++ b/')}

def main(wt, pre, br):
    base = subprocess.run(['git', '-C', wt, 'merge-base', pre, br], capture_output=True, text=True).stdout.strip(); bs = set(show(wt, base, SERIES))
    mn = [p for p in show(wt, pre, SERIES) if p.strip() and p not in bs]; bn = [p for p in show(wt, br, SERIES) if p.strip() and p not in bs]
    bf = set().union(*[files(wt, br, p) for p in bn]) if bn else set(); out = []
    for p in mn:
        same = files(wt, pre, p) & bf
        if same: out.append(f'{p}（{"、".join(sorted(os.path.basename(f) for f in same))}）')
    print('、'.join(out)); return 0

if __name__ == '__main__': sys.exit(main(*sys.argv[1:4]))
