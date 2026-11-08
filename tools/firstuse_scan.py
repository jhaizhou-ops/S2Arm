#!/usr/bin/env python3
# 首遇现编扫描（10-23 总指挥：jhz 实机走到自动路线没去的地方，同局 5 次着色器首遇现编、三次完全卡顿，记分板抓不到）：
#   firstuse_scan.py <局目录或 host.log>  → 一行：合计<TAB>说明；合计 = 现建管线 + 程序编译中跳过绘制 + 特化慢
#   host.log 认三种行（graphics/metal/gal_core.m「管线现建：」、「【首遇】程序 N 编译中，跳过本次绘制」、「【首遇】管线特化慢」），不读 frames.tsv
#   （App 只在测试局写它，jhz 实机局目录里即便有也是上一局测试的）。只读，不判格
import glob, os, re, sys
p = sys.argv[1]; d = p if os.path.isdir(p) else os.path.dirname(p) or '.'; hp = os.path.join(p, 'host.log') if os.path.isdir(p) else p
try: hl = open(hp, errors='replace').read()
except OSError: hl = ''
# 同目录的往局日志 logs/host-<起局时刻>.log（App 每局一份、留 10 份；dev_run.sh jhzplay 只存不是测试局的那几份）一并扫
for x in (sorted(glob.glob(os.path.join(p, 'logs', 'host-*.log'))) if os.path.isdir(p) else []):
    try: hl += open(x, errors='replace').read()
    except OSError: pass
pso = len(re.findall(r'管线现建：', hl)); skip = len(re.findall(r'【首遇】程序 \d+ 编译中', hl)); spec = hl.count('【首遇】管线特化慢')
n = pso + skip + spec
print(f'{n}\t现建管线 {pso}、程序编译中跳过绘制 {skip}、特化慢 {spec}')
