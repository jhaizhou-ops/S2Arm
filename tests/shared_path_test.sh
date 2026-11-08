#!/bin/bash
# 门禁：每次
# 共享位置扫描单测（tools/shared_path_lint.py，约 2 秒）：bash tests/shared_path_test.sh
# 期望：本仓库共享位置全部登记 → 退出 0；临时仓库里加一个没登记的共享缺省（run/s2arm 下新目录、/tmp 固定名、Python '~/…'）→ 退出 1 且点名这三处；
# 私有写法（mktemp、$$ 临时名、局目录变量、C 里的按位取反 ~0u）不报
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
o=$(cd "$H" && python3 tools/shared_path_lint.py 2>&1); r=$?
ck "本仓库：共享位置全部登记（$(echo "$o" | tail -1 | cut -c1-120)）" '[ $r = 0 ]'
[ $r = 0 ] || echo "$o" | head -10
mkdir -p $T/repo/tools $T/repo/native/src; cp "$H/tools/shared_path_lint.py" "$H/tools/shared_paths.tsv" $T/repo/tools/
cat > $T/repo/tools/new.sh <<'EOF'
OUT=${OUT:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/newshared}; echo x > /tmp/fixed_name.log
L=$(mktemp -d); echo y > /tmp/ok_$$.log; echo z > "$D/frames.tsv"; S=${S:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/sched}
EOF
printf "import os\nP = os.path.expanduser('~/.s2arm/run/s2arm/pyshared')\n" > $T/repo/tools/new.py
printf 'unsigned m = ~0u; unsigned long a = x & ~15ull;\n' > $T/repo/native/src/bits.c
(cd $T/repo && git init -q && git add -A) > /dev/null
o=$(cd $T/repo && python3 tools/shared_path_lint.py 2>&1); r=$?
ck "新加未登记的共享缺省 → 红（退出 1）" '[ $r = 1 ]'
ck "点名三处：run/s2arm/newshared、/tmp/fixed_name.log、Python 的 pyshared" 'grep -q "newshared：tools/new.sh:1" <<< "$o" && grep -q "/tmp/fixed_name.log" <<< "$o" && grep -q "pyshared：tools/new.py:2" <<< "$o"'
ck "私有写法不报（mktemp / \$\$ 临时名 / 局目录变量 / 已登记的 sched / C 的 ~0u）" '[ "$(grep -c "^未登记" <<< "$o")" = 3 ]'
# 登记表配 merge=union（10-30 列车线）：同一路径完全相同的两行无害；同一路径两行内容不一致（两支都改了同一行、并集留下新旧两行）→ 红、点名路径
grep -v '^#' "$H/tools/shared_paths.tsv" | head -1 >> $T/repo/tools/shared_paths.tsv; o=$(cd $T/repo && python3 tools/shared_path_lint.py 2>&1); r=$?
ck "登记表同一路径完全相同的两行：不因重复报红（只剩上面那三处未登记，rc=${r}）" '[ $r = 1 ] && ! grep -q "两行内容不一致" <<< "$o"'
k=$(grep -v '^#' "$H/tools/shared_paths.tsv" | head -1 | cut -f1); printf '%s\t别的线\t改过的用途\t改过的规则\n' "$k" >> $T/repo/tools/shared_paths.tsv
o=$(cd $T/repo && python3 tools/shared_path_lint.py 2>&1); r=$?
ck "登记表同一路径两行内容不一致 → 红、点名 ${k}（rc=${r}）" '[ $r = 1 ] && grep -qF "两行内容不一致（并集合并时两支都改了这一行）：$k" <<< "$o"'
# 文档根规则（11-07 Hades 白屏）：源码自己拼 $HOME/Documents → 红、点名文件:行；改调 s2a_docs.h、测试文件、白名单文件、注释里的不报
mkdir -p $T/d/tools $T/d/native/src $T/d/native/tests $T/d/gfx/loop $T/d/tests/autoplay; cp "$H/tools/shared_path_lint.py" "$H/tools/shared_paths.tsv" $T/d/tools/
printf 'void a(char *p, unsigned n, const char *h) {\n    snprintf(p, n, "%%s/Documents/wire", h);\n}\n' > $T/d/native/src/bad.c
printf 'NSString *r = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];\n' > $T/d/native/src/bad.m
printf 'static void o(void) { char d[64]; snprintf(d, 64, "%%s/Documents", "/h"); }\n' > $T/d/tests/autoplay/ap.c
printf '#include "s2a_docs.h"\n// 注释里写 "%%s/Documents" 不算\nvoid b(char *p, unsigned n) { s2a_docs_path(p, n, "wire"); }\n' > $T/d/native/src/good.c
printf 'void t(char *p) { snprintf(p, 9, "%%s/Documents", "/h"); }\n' > $T/d/native/tests/t_x.c
printf 'string d = Path.Combine(h, "Documents");\n' > $T/d/gfx/loop/ShaderPack.cs
(cd $T/d && git init -q && git add -A) > /dev/null
o=$(cd $T/d && python3 tools/shared_path_lint.py 2>&1); r=$?
ck "源码自己拼 \$HOME/Documents → 红（rc=${r}）" '[ $r = 1 ]'
ck "点名三处：runtime/src/bad.c:2、runtime/src/bad.m:1、tests/autoplay/ap.c:1" 'grep -q "Documents.*runtime/src/bad.c:2$" <<< "$o" && grep -q "runtime/src/bad.m:1$" <<< "$o" && grep -q "tests/autoplay/ap.c:1$" <<< "$o"'
ck "改调 s2a_docs.h / 注释 / 测试文件 t_* / 白名单 ShaderPack.cs 不报（只报上面 3 处）" '[ "$(grep -c "^自己拼" <<< "$o")" = 3 ]'
rm -rf $T; [ $bad = 0 ] && echo "shared_path 单测全过" || { echo "shared_path 单测有不通"; exit 1; }
