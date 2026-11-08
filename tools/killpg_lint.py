#!/usr/bin/env python3
"""扫「把信号发给进程组」的写法：shell 的 kill / pkill 目标是负号进程组（-$x、-"$(…)"、\\$ 转义的也算、-1）或 pkill -g，
Python 的 os.killpg / os.kill(-…)。经 safe_killpg 的、kill -0（只探测）的不报。用法：killpg_lint.py <文件>…  → 每处一行「文件:行: 原文」"""
import re, sys
TOK = re.compile(r'''(?:^|[\s;&|(`{])(p?kill)\b([^;&|)`#\n]*)''')
def hits(line):
    out = []
    if 'safe_killpg' in line: return out
    for m in TOK.finditer(line):
        cmd, rest = m.group(1), m.group(2)
        toks = rest.split()
        if not toks: continue
        if cmd == 'pkill':
            if any(t in ('-g', '--pgroup') or t.startswith('-g') for t in toks): out.append('pkill -g')
            continue
        args = [t for t in toks if t != '--']
        sig_done = False; tgt = []
        for t in args:
            if not sig_done and re.fullmatch(r'-[A-Z]+[0-9]*|-[0-9]+|-s|-n', t) and t not in ('-1',):
                sig_done = True; continue
            tgt.append(t)
        if tgt and tgt[0] == '0' or (args and args[0] == '-0'): continue
        for t in tgt:
            u = t.strip('"\'')
            if u == '-1' or re.match(r'-\\?\$|-["\\]+\$|-\$', t.lstrip('"')) or re.match(r'''^-["'\\]*\$''', t) or re.match(r'^"-\\?\$', t):
                out.append(t); break
    if re.search(r'os\.killpg|os\.kill\(\s*-', line): out.append('os.killpg')
    return out
bad = 0
for f in sys.argv[1:]:
    try: L = open(f, errors='replace').read().split('\n')
    except OSError: continue
    for i, l in enumerate(L, 1):
        s = l.lstrip()
        if s.startswith('#'): continue
        h = hits(l)
        if h: bad += 1; print(f'{f}:{i}: {l.strip()[:200]}')
sys.exit(1 if bad else 0)
