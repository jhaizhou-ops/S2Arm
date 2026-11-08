#!/bin/bash
# 门禁：每次
#   （11-01：手册引用的是仓库任意路径，任何删改都可能让它红；原先只在改 docs/排查/* 时跑，b1ded6e87 删了 9 个被引用的工具没触发，main 无缓存实跑才红。约 8 秒）
# 排查手册自检：docs/排查/ 下全部手册 + skills/native-triage/SKILL.md 里，
#   ① 相对链接（](...)）和反引号里的仓库路径（`runtime/src/far.c:318` 去掉 :行号）都存在；带 * 或 <占位> 的路径模式不查
#   ② 反引号里引用的 host.log 红行（含【红】）在源码里搜得到：去掉【红】，截到第一个占位（单个字母 N / A / r、<…>、…、（、0x、%）之前的前缀，
#      在 native / services / gfx / tools / ryujinx / platforms / pack 的 .c .m .h .cs .py .sh 里按原文搜（源码里【红】常由 Red.Report 统一加，所以不带它搜）
#   ③ 负对照：一份合成手册写不存在的路径、坏链接和源码里没有的红行，必须报出 3 处
# 门禁覆盖：docs/排查/* skills/native-triage/* tests/triage_docs_test.sh
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cat > "$T/check.py" << 'EOF'
import os, re, sys
root, docs = sys.argv[1], sys.argv[2:]
TOP = {'runtime', 'ios', 'services', 'tools', 'tests', 'compat', 'graphics', 'translator', 'docs', 'android', 'launchers', 'macos', 'platform', 'shell', 'skills', 'pack'}
SRC = ('runtime', 'ios', 'services', 'graphics', 'translator', 'tools', 'compat', 'android', 'launchers', 'macos', 'platform', 'shell', 'pack')
text = []
for d in SRC:
    for base, dirs, files in os.walk(os.path.join(root, d)):
        dirs[:] = [x for x in dirs if x not in ('bin', 'obj', 'build', '.git')]
        for f in files:
            if f.endswith(('.c', '.m', '.h', '.cs', '.py', '.sh')):
                try: text.append(open(os.path.join(base, f), encoding='utf-8', errors='ignore').read())
                except OSError: pass
src = '\n'.join(text)
CUT = ('（', '<', '…', '0x', '%')
def prefix(span):
    s = span.replace('【红】', '', 1).strip()
    for c in CUT:
        i = s.find(c)
        if i >= 0: s = s[:i]
    keep = []
    for tok in s.split(' '):
        if re.fullmatch(r'[A-Za-z]', tok): break
        keep.append(tok)
    return ' '.join(keep).strip()
bad = paths = reds = 0
for doc in docs:
    body = open(doc, encoding='utf-8').read()
    here = os.path.dirname(doc)
    for m in re.finditer(r'\]\(([^)#\s]+)(?:#[^)]*)?\)', body):
        t = m.group(1)
        if re.match(r'[a-z]+://', t): continue
        paths += 1
        if not os.path.exists(os.path.normpath(os.path.join(here, t))):
            print(f'  ✗ {os.path.relpath(doc, root)}：链接 {t} 不存在'); bad += 1
    for m in re.finditer(r'`([^`\n]+)`', body):
        span = m.group(1)
        if span.strip() == '【红】': continue   # 指红标本身，不是日志行
        if '【红】' in span:
            reds += 1
            p = prefix(span)
            if len(p) < 2 or p not in src:
                print(f'  ✗ {os.path.relpath(doc, root)}：红行「{span}」的前缀「{p}」源码里搜不到'); bad += 1
            continue
        t = re.sub(r':\d+(,\d+)*$', '', span.strip())
        if ' ' in t or '*' in t or '<' in t or '/' not in t or t.split('/')[0] not in TOP: continue
        paths += 1
        if not os.path.exists(os.path.join(root, t.rstrip('/'))):
            print(f'  ✗ {os.path.relpath(doc, root)}：路径 {t} 不存在'); bad += 1
print(f'扫 {len(docs)} 份手册：路径 {paths} 个、红行 {reds} 条；不符 {bad} 处')
sys.exit(1 if bad else 0)
EOF
rc=0
shopt -s nullglob; D=("$H"/docs/排查/*.md "$H"/skills/native-triage/SKILL.md)
python3 "$T/check.py" "$H" "${D[@]}" || rc=1
mkdir -p "$T/docs/排查" && cat > "$T/docs/排查/坏.md" << 'EOF'
见 `runtime/src/没有这个文件.c:12`、[另一份](不存在.md)，日志里会有 `【红】这一行源码里没有 N 次`。真有的：`runtime/src/far.c`、`【红】CRASH 信号 N 地址 A`。
EOF
n=$(python3 "$T/check.py" "$H" "$T/docs/排查/坏.md" | grep -c '✗')
[ "$n" = 3 ] && echo "通 ③ 负对照：合成手册报出 3 处（坏路径 / 坏链接 / 源码里没有的红行）" || { echo "  ✗ ③ 负对照：期望报 3 处，真结果 $n 处"; rc=1; }
[ $rc = 0 ] && echo "排查手册自检全过" || { echo "排查手册自检有不通"; exit 1; }
