#!/usr/bin/env python3
"""Metal 4 棘轮（只许减不许增）的统一判定：渲染器 graphics/metal 与直连 graphics/nvn/gfx 两份计数，超基线时点名新增在哪。
计数仍由各自的 mtl4_count.sh 算（单一来源，规则写在那里：不含 // 注释；渲染器不含 gal_be.h 对照表）。
超基线 → 列本支新增的出现处：<文件>:<行>（<所在函数>）<那行>，按 git diff -U0 <基准> 的加行里带 MTL4 的找。
  基准：$MTL4_BASE；没给时 origin/main 与 HEAD 的合并基点；合并树（HEAD 是合并提交，列车 / 入队预检）取 HEAD^1。取不到 → 按文件列计数（-v）
用法：python3 tools/mtl4_ratchet.py [metal|nvn …]（缺省两份都判）→ 每份一行「通 / 不通 …」；任一份超基线退出 1
10-30 起（总指挥）：这一项在 graphics/gate.sh 里两次判红都藏在结果段里要人翻，入队预检又不跑 gfx 钩子（慢步）→ 拆出来，tests/mtl4_ratchet_test.sh 秒级跑。"""
import os, re, subprocess, sys

R = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
SCOPES = {   # 名字 → (计数脚本, 基线文件, 计数的文件（相对仓库根，与计数脚本同一规则）, 说明)
    'metal': ('graphics/metal/tools/mtl4_count.sh', 'graphics/metal/tools/mtl4_baseline.txt',
              lambda: sorted(f'graphics/metal/{n}' for n in os.listdir(os.path.join(R, 'graphics/metal')) if re.fullmatch(r'gal_.*\.[mh]', n) and n != 'gal_be.h'),
              '渲染器 MTL4 直接调用（新代码走 graphics/metal/gal_be.h）'),
    'nvn': ('graphics/nvn/tools/mtl4_count.sh', 'graphics/nvn/tools/mtl4_baseline.txt',
            lambda: sorted(f'graphics/nvn/gfx/{d}/{n}' for d, ext in (('nvn', ('.m', '.h', '.inc', '.c')), ('tex', ('.m', '.h', '.c')))
                           if os.path.isdir(os.path.join(R, 'graphics/nvn/gfx', d)) for n in os.listdir(os.path.join(R, 'graphics/nvn/gfx', d)) if n.endswith(ext)),
            '直连 MTL4 出现处（新代码只经 nvn_mtl.m 的包装，变量用 id）'),
}
TOK = re.compile(r'(^|[^A-Za-z0-9_])MTL4[A-Za-z]*')
FN = re.compile(r'^(?:static\s+|inline\s+|extern\s+)*[A-Za-z_][\w<>\s\*,]*?\b([A-Za-z_]\w*)\s*\([^;]*$')   # 列首起的函数头（不以分号结尾）

def git(*a):
    r = subprocess.run(['git', '-C', R, *a], capture_output=True, text=True); return r.stdout.strip() if r.returncode == 0 else None

def base():
    if os.environ.get('MTL4_BASE'): return os.environ['MTL4_BASE']
    if git('rev-parse', '-q', '--verify', 'HEAD^2'): return git('rev-parse', 'HEAD^1')   # 合并树：第一亲本 = main
    return git('merge-base', 'HEAD', 'origin/main')

def func_at(lines, i):   # 第 i 行（0 起）所在函数名：往上找最近的列首函数头
    for j in range(i, -1, -1):
        m = FN.match(lines[j])
        if m and m.group(1) not in ('if', 'for', 'while', 'switch', 'return', 'sizeof'): return m.group(1)
    return '?'

def new_sites(files, b):
    out = []
    d = git('diff', '-U0', '--no-color', b, '--', *files) if b else None
    if d is None: return None
    f = ln = None
    for row in d.splitlines():
        if row.startswith('+++ '): f = row[6:] if row.startswith('+++ b/') else None
        elif row.startswith('@@'): ln = int(re.search(r'\+(\d+)', row).group(1))
        elif row.startswith('+') and f and ln is not None:
            if TOK.search(re.sub(r'//.*', '', row[1:])):
                try: lines = open(os.path.join(R, f), encoding='utf-8', errors='replace').read().split('\n')
                except OSError: lines = []
                out.append(f'{f}:{ln}（{func_at(lines, ln - 1) if lines else "?"}）{row[1:].strip()[:120]}')
            ln += 1
    return out

def main():
    names = sys.argv[1:] or list(SCOPES); bad = 0; b = None
    for n in names:
        sh, bl, files, what = SCOPES[n]
        cnt = int(subprocess.run(['bash', os.path.join(R, sh)], capture_output=True, text=True).stdout.split()[-1]); lim = int(open(os.path.join(R, bl)).read().split()[0])
        if cnt <= lim:
            print(f'通 {what}：{cnt}（基线 ≤ {lim}）'); continue
        bad = 1; b = b or base(); sites = new_sites(files(), b)
        if sites:
            where = '；'.join(sites)
        else:
            per = subprocess.run(['bash', os.path.join(R, sh), '-v'], capture_output=True, text=True).stdout.split('\n')[:-2]
            where = f'取不到基准{"、或差异里没有新增行" if sites == [] else ""}，按文件计数：' + '，'.join(x for x in per if x)
        print(f'不通 {what}：{cnt} > 基线 {lim}；新增在 {where}（只许减：改经包装，或真减了一处就同笔把 {bl} 改小）')
    sys.exit(bad)

if __name__ == '__main__': main()
