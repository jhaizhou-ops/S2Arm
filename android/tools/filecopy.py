#!/usr/bin/env python3
"""文件复制：文件系统支持写时复制（btrfs/XFS/APFS 的 FICLONE）时共享数据块，否则普通复制。

出包链路会整份复制几十 GB 的 ROM 数据（make_pack 的产物包、game_apk.py --resources 的资源包）。
在同一文件系统上，复制后的两份内容各自独立（写任一份都触发 CoW），所以共享数据块对调用方是透明的；
不支持 FICLONE 的宿主（macOS 的 fcntl 没有这个 ioctl、tmpfs、网络盘等）自动退回 shutil.copy2。

    from filecopy import copy_file
    copy_file(src, dst)   # True = 共享了数据块；False = 普通复制。两种情况下内容/权限/时间戳一致。
"""
import fcntl
import os
import shutil

# Linux 的 ioctl 号；macOS 没有 FICLONE（APFS 用 clonefile(2)），下面的 ioctl 会失败并走普通复制。
_FICLONE = getattr(fcntl, 'FICLONE', 0x40049409)


def copy_file(src, dst):
    """复制 src 到 dst；成功共享数据块返回 True，普通复制返回 False。"""
    os.makedirs(os.path.dirname(dst) or '.', exist_ok=True)
    try:
        with open(src, 'rb') as a, open(dst, 'wb') as b:
            fcntl.ioctl(b.fileno(), _FICLONE, a.fileno())
        shutil.copystat(src, dst)
        return True
    except OSError:
        shutil.copy2(src, dst)
        return False
