#!/usr/bin/env python3
"""子步计时：python3 tools/tm.py <步名> <记账 tsv> -- <命令…>
跑命令（标准输出 / 错误照原样），退出码照传；往记账 tsv 追加一行「步名 墙钟秒 user 秒 sys 秒 退出码」（CPU 取这条命令及其全部子进程，RUSAGE_CHILDREN 差值）。
用途：出包段拆账（pack/ipa.sh），按墙钟和 CPU 秒分清是算力瓶颈还是等待。"""
import resource, subprocess, sys, time

name, log = sys.argv[1], sys.argv[2]
cmd = sys.argv[sys.argv.index('--') + 1:]
r0 = resource.getrusage(resource.RUSAGE_CHILDREN); t0 = time.time()
rc = subprocess.call(cmd)
r1 = resource.getrusage(resource.RUSAGE_CHILDREN); w = time.time() - t0
with open(log, 'a', encoding='utf-8') as f:
    f.write(f'{name}\t{w:.1f}\t{r1.ru_utime - r0.ru_utime:.1f}\t{r1.ru_stime - r0.ru_stime:.1f}\t{rc}\n')
sys.exit(rc)
