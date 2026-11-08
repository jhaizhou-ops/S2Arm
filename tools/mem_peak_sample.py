#!/usr/bin/env python3
# 命令进程树的物理足迹峰值采样（内存准入 tools/mem_admit.sh 用）：mem_peak_sample.py <根 pid> <输出文件> [间隔秒，缺省 1]
# 每个间隔把根 pid 及其全部子孙的 ri_phys_footprint（同 tools/phys_footprint.py，与 iOS 判杀同口径）加总，峰值（KB）只在涨时原子写进输出文件；根 pid 不在了就退出。
# 取不到任何读数（进程一瞬间就结束）= 不写文件，调用方按「没有实测」处理。系统 MTLCompilerService 由 launchd 起、不在进程树里，不计入。
import os, subprocess, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import phys_footprint

def tree(root):
    out = subprocess.run(['ps', '-axo', 'pid=,ppid='], capture_output=True, text=True).stdout
    kids = {}
    for l in out.splitlines():
        a = l.split()
        if len(a) == 2 and a[0].isdigit() and a[1].isdigit():
            kids.setdefault(int(a[1]), []).append(int(a[0]))
    res = [root]
    i = 0
    while i < len(res):
        res.extend(kids.get(res[i], []))
        i += 1
    return res

def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True

def main():
    if len(sys.argv) < 3 or not sys.argv[1].isdigit():
        sys.exit('用法：mem_peak_sample.py <根 pid> <输出文件> [间隔秒]')
    root, out = int(sys.argv[1]), sys.argv[2]
    iv = float(sys.argv[3]) if len(sys.argv) > 3 else 1.0
    peak = 0
    while True:
        tot = 0
        for p in tree(root):
            r = phys_footprint.read(p)
            if r:
                tot += r[0]
        if tot > peak:
            peak = tot
            tmp = out + '.tmp'
            with open(tmp, 'w') as f:
                f.write(str(peak) + '\n')
            os.replace(tmp, out)
        if not alive(root):
            break
        time.sleep(iv)

if __name__ == '__main__':
    main()
