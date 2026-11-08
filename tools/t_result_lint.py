#!/usr/bin/env python3
"""原生 / 图形单测结论行静态检查（11-07 总指挥：一晚两支——warm-bump、buf-reg-scalable——单测全过、只因没打「✓ t_」被原生门禁判红）。
本支新增或改动的 runtime/tests/**/t_*.c|m、graphics/nvn/tests/**/t_*.c|m，必须能静态看出会打结论行，任一即可：
  ① 源码里有字面「✓ t_<名>」；② 用共用宏 S2A_T_RESULT("t_<名>", …)（runtime/include/s2a_t_result.h）；
  ③ 源码里有「"✓"」字面（三元式 bad ? "✗" : "✓"）且格式串里有 t_<名>；④ runtime/ 或 graphics/ 下某个 .mk 里 echo「✓ t_<名>」
找不到 → 打「<文件>: 没有门禁结论行…」并退 1。没改到的老文件不查。
  python3 tools/t_result_lint.py [--base <提交>]（缺省 origin/main）；--files <文件…> 只查给的（单测用）"""
import os, re, subprocess, sys

PAT = re.compile(r'^(runtime/tests|graphics/nvn/tests)/(.*/)?t_[^/]*\.(c|m)$')


def changed(base):
    r = subprocess.run(['git', 'diff', '--name-only', '--diff-filter=AMR', f'{base}...HEAD'], capture_output=True, text=True)
    if r.returncode: r = subprocess.run(['git', 'diff', '--name-only', '--diff-filter=AMR', base, 'HEAD'], capture_output=True, text=True)
    return [f for f in r.stdout.split('\n') if PAT.match(f)]


def mk_text():
    out = []
    for top in ('native', 'gfx'):
        for dp, _, fn in os.walk(top):
            for f in fn:
                if f.endswith('.mk'):
                    try: out.append(open(os.path.join(dp, f), encoding='utf-8', errors='replace').read())
                    except OSError: pass
    return '\n'.join(out)


def ok(path, mk):
    name = os.path.splitext(os.path.basename(path))[0]
    try: src = open(path, encoding='utf-8', errors='replace').read()
    except OSError: return True   # 删了 / 改名走掉的不查
    return (f'✓ {name}' in src or re.search(r'S2A_T_RESULT\(\s*"' + re.escape(name) + r'"', src) is not None
            or ('"✓' in src and name in src) or f'✓ {name}' in mk)


def main(a):
    base = a[a.index('--base') + 1] if '--base' in a else 'origin/main'
    fs = a[a.index('--files') + 1:] if '--files' in a else changed(base)
    mk = mk_text(); bad = [f for f in fs if PAT.match(f) and not ok(f, mk)]
    for f in bad:
        n = os.path.splitext(os.path.basename(f))[0]
        print(f'{f}:1: 没有门禁结论行：原生门禁要「✓ {n}」（不通打「✗ {n}」），rc=0 没这行也判红。'
              f'写法：#include "s2a_t_result.h" 后 return S2A_T_RESULT("{n}", bad);，或 printf("%s {n}：…\\n", bad ? "✗" : "✓")')
    print(f't_result_lint：查 {len(fs)} 个改动单测，{len(bad)} 个没有结论行')
    return 1 if bad else 0


if __name__ == '__main__': sys.exit(main(sys.argv[1:]))
