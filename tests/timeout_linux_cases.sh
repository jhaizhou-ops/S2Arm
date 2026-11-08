#!/bin/bash
# Linux 真实 Perl timeout：后台 sleep 孙进程必须消失；仅自建 session / PID 清理，无全局 pkill。
set -euo pipefail
[ "$(uname -s)" = Linux ] || exit 0
R=$(cd "$(dirname "$0")/.." && pwd)
python3 - "$R/tools/bin/timeout" <<'PY'
import ctypes
import os
import pathlib
import signal
import subprocess
import sys
import tempfile
import time

# 收养并回收测试孙进程，避免容器 PID 1 不 reap 导致僵尸被误认成存活。
libc = ctypes.CDLL(None, use_errno=True)
if libc.prctl(36, 1, 0, 0, 0) != 0:  # PR_SET_CHILD_SUBREAPER，仅本测试进程
    raise OSError(ctypes.get_errno(), 'PR_SET_CHILD_SUBREAPER')

def identity(pid):
    try:
        fields = pathlib.Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()
        return int(fields[3]), fields[19]  # session, starttime
    except FileNotFoundError:
        return None

with tempfile.TemporaryDirectory(prefix='s2a-timeout-linux-') as tmp:
    pidfile = pathlib.Path(tmp) / 'sleep.pid'
    # timeout 是新 session 的首进程；bash 是其子进程，后台 sleep 是孙进程。
    errfile = open(pathlib.Path(tmp) / 'stderr', 'w+')
    p = subprocess.Popen([sys.argv[1], '-k', '1', '2', 'bash', '-c',
        'sleep 30 & echo "$!" > "$1"; wait', '_', str(pidfile)],
        start_new_session=True, stdout=subprocess.DEVNULL, stderr=errfile)
    owned = {p.pid: identity(p.pid)}
    try:
        deadline = time.monotonic() + 1.5
        while not pidfile.exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        assert pidfile.exists(), '后台 sleep 未就绪'
        child = int(pidfile.read_text())
        owned[child] = identity(child)
        assert child > 1 and owned[child] and owned[child][0] == p.pid, '孙进程不属于测试 session'
        # 保存本次已存在的完整自建 PID 树身份，失败也仅按 PID + starttime 清理。
        for entry in pathlib.Path('/proc').iterdir():
            if entry.name.isdigit():
                pid = int(entry.name)
                ident = identity(pid)
                if ident and ident[0] == p.pid:
                    owned[pid] = ident
        p.wait(timeout=8)
        errfile.seek(0)
        assert p.returncode == 124, (p.returncode, errfile.read())
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            try:
                got, _ = os.waitpid(child, os.WNOHANG)
            except ChildProcessError:
                got = 0
            if identity(child) is None:
                break
            time.sleep(0.01)
        assert identity(child) is None, f'后台 sleep 孙进程仍在：{child}'
        print('Linux 真实仓库 timeout：退出 124，后台 sleep 孙进程已消失（/proc 不存在）')
    finally:
        # 不使用负进程组 / 名字匹配；只杀本测试记录且身份未变的正 PID。
        for pid, ident in reversed(list(owned.items())):
            if pid > 1 and ident and ident[0] == p.pid and identity(pid) == ident:
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        p.wait(timeout=3)
        errfile.close()
        for pid in owned:
            if pid == p.pid:
                continue
            try:
                os.waitpid(pid, 0)
            except ChildProcessError:
                pass
PY
