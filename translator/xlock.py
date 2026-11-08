#!/usr/bin/env python3
# 跨平台独占文件锁（#1100 W6，11-04 Windows 出包线）：with xlock.held(<锁文件路径>): …——多进程只让一个进去，进程退出 / 文件关闭即释放。
#   Mac / Linux：fcntl.flock（同原先各工具里的写法）；Windows：msvcrt 锁第 1 字节、拿不到每 0.5 秒重试（msvcrt.LK_LOCK 只重试 10 秒，首次编库就要更久）。
#   dsh_batch.py（编 C# 批量进程）、spvc_inproc.py（编 spirv-cross 库 / 命令行）共用
import contextlib, os, sys, time


@contextlib.contextmanager
def held(path):
    with open(path, 'a+') as f:
        if sys.platform == 'win32':
            import msvcrt
            while True:
                try: f.seek(0); msvcrt.locking(f.fileno(), msvcrt.LK_NBLCK, 1); break
                except OSError: time.sleep(0.5)
        else:
            import fcntl
            fcntl.flock(f, fcntl.LOCK_EX)
        yield
