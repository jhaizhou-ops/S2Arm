#!/usr/bin/env python3
"""打一个进程的物理足迹（KB）：libproc proc_pid_rusage 的 ri_phys_footprint，与 iOS 判杀（jetsam）同口径。
用法：phys_footprint.py <pid> [--rss]（--rss 再打一列常驻页集 KB，只作对照）。进程不在或取不到时不打、退出 1。
runtime/run_mac.sh 每秒调一次判内存上限（11-01 起由 ps rss 改为足迹：rss 含文件映射的干净页，iOS 不按它杀）。"""
import ctypes, sys

RUSAGE_INFO_V0 = 0
class RusageInfoV0(ctypes.Structure):
    _fields_ = [('uuid', ctypes.c_uint8 * 16), ('user_time', ctypes.c_uint64), ('system_time', ctypes.c_uint64),
                ('pkg_idle_wkups', ctypes.c_uint64), ('interrupt_wkups', ctypes.c_uint64), ('pageins', ctypes.c_uint64),
                ('wired_size', ctypes.c_uint64), ('resident_size', ctypes.c_uint64), ('phys_footprint', ctypes.c_uint64),
                ('proc_start_abstime', ctypes.c_uint64), ('proc_exit_abstime', ctypes.c_uint64)]

def read(pid):
    lib = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
    ri = RusageInfoV0()
    if lib.proc_pid_rusage(ctypes.c_int(pid), ctypes.c_int(RUSAGE_INFO_V0), ctypes.byref(ri)) != 0:
        return None
    return ri.phys_footprint // 1024, ri.resident_size // 1024

if __name__ == '__main__':
    if len(sys.argv) < 2 or not sys.argv[1].isdigit():
        sys.exit('用法：phys_footprint.py <pid> [--rss]')
    r = read(int(sys.argv[1]))
    if r is None:
        sys.exit(1)
    print(f'{r[0]} {r[1]}' if '--rss' in sys.argv[2:] else r[0])
