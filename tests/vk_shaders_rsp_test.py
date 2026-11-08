#!/usr/bin/env python3
"""vk_shaders.py 合库走响应文件（11-06 天眼银河 2 第二包：3795 个 .air 拼在 metallib 命令行上超 Windows 32767 字符，WinError 206）：python3 tests/vk_shaders_rsp_test.py
期望（手写）：5000 个 .air（每个路径约 80 字符，直拼约 40 万字符）→ metallib 命令行只带「@<响应文件>」、总长 < 2000 字符；响应文件 5000 行、
  每行一个带引号的路径、顺序同输入；调用后响应文件删掉；Windows 口径（os.name 置 nt）下路径里的反斜杠换成正斜杠。外部命令一律替身，不调 metal / metallib"""
import os, sys, tempfile
from pathlib import Path
from unittest import mock
R = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(R / 'translator'))
import vk_shaders as vs
bad = 0
def chk(name, want, got):
    global bad
    ok = want == got; bad += not ok; print(f'{"通" if ok else "不通"} {name}：期望 {want!r} → 真结果 {got!r}')
for nt in (False, True):
    with tempfile.TemporaryDirectory() as t:
        msls = [os.path.join(t, f'shader_{i:05d}_' + 'x' * 50 + '.metal') for i in range(5000)]
        seen = {}
        def run(cmd, **kw):
            if 'metallib' in os.path.basename(str(cmd[0])) or 'metallib' in cmd:
                at = [c for c in cmd if str(c).startswith('@')]
                seen['len'] = len(' '.join(map(str, cmd))); seen['rsp'] = open(at[0][1:], encoding='utf-8').read().splitlines() if at else None; seen['path'] = at[0][1:] if at else None
            class P: returncode = 0; stderr = ''
            return P()
        sep = '\\' if nt else os.sep
        with mock.patch.object(vs.subprocess, 'run', run), mock.patch.object(vs.os, 'name', 'nt' if nt else os.name), mock.patch.object(vs.os, 'sep', sep):
            vs.metallib(msls, os.path.join(t, 'out'), 'iphoneos', [])
        want = ['"' + (m[:-6] + '.iphoneos.air').replace(sep, '/' if nt else sep) + '"' for m in msls]
        tag = 'Windows 口径' if nt else '本机口径'
        chk(f'{tag}：metallib 命令行只带响应文件、长度 < 2000', (True, True), (seen.get('rsp') is not None, seen.get('len', 10**9) < 2000))
        chk(f'{tag}：响应文件 5000 行、带引号、顺序同输入', want, seen.get('rsp'))
        chk(f'{tag}：调用后响应文件已删', False, bool(seen.get('path')) and os.path.exists(seen['path']))
print(f'{"✓" if not bad else "✗"} vk_shaders_rsp：{bad} 不通')
sys.exit(1 if bad else 0)
