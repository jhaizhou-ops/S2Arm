#!/usr/bin/env python3
# 登记段核对：<可执行文件> <静态库或 .o>...。直连各层把入口登记在 __DATA,sw* 段里（GL swgl / swglb、Vulkan swhle / swvkb、NVN swnvn），
#   没有对外被引用符号的 .o 静态链接时会整个被丢（10-25 数码宝贝 gl_buf.o：13 个 GL 入口查表回空）。可执行文件里每个 sw* 段的字节数必须等于
#   输入各 .o 同名段之和；少了列出带该段的 .o。退出 0 = 全齐，1 = 有段少了。给 .o 时按单个目标文件算
import subprocess, sys, tempfile, os, re, collections
def secs(path):
    out = subprocess.run(['otool', '-l', path], capture_output=True, text=True).stdout
    res, name, seg = {}, None, None
    for line in out.splitlines():
        t = line.split()
        if len(t) == 2 and t[0] == 'sectname': name = t[1]
        elif len(t) == 2 and t[0] == 'segname': seg = t[1]
        elif len(t) == 2 and t[0] == 'size' and seg == '__DATA' and name and name.startswith('sw'): res[name] = res.get(name, 0) + int(t[1], 16)
    return res
x = secs(sys.argv[1]); total = collections.Counter(); who = collections.defaultdict(list)
with tempfile.TemporaryDirectory() as w:
    for i, a in enumerate(sys.argv[2:]):
        d = os.path.join(w, str(i)); os.mkdir(d)
        if a.endswith('.a'): subprocess.run(['ar', 'x', a], cwd=d, check=True)
        else: os.symlink(os.path.abspath(a), os.path.join(d, os.path.basename(a)))
        for o in sorted(os.listdir(d)):
            for n, s in secs(os.path.join(d, o)).items(): total[n] += s; who[n].append(f'{o}({s})')
bad = 0
for n in sorted(set(total) | set(x)):
    ok = x.get(n, 0) == total[n]; bad |= not ok
    print(f'{n}：可执行文件 {x.get(n, 0)} / 各 .o 之和 {total[n]} → {"齐" if ok else "少 %d 字节" % (total[n] - x.get(n, 0))}' + ('' if ok else '；带该段的 .o：' + ' '.join(who[n])))
sys.exit(1 if bad else 0)
