#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 门禁覆盖：graphics/tools/shbake/pso_dist.sh
# 每次复制生产脚本原文，只替换相邻 pso_chunk.sh 的编译边界；不替换排序/领片代码。
set -euo pipefail
H=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/repo/graphics/tools/shbake" "$T/input space" "$T/bin"
cp "$H/graphics/tools/shbake/pso_dist.sh" "$T/repo/graphics/tools/shbake/"
P=$T/repo/graphics/tools/shbake/pso_dist.sh
cat > "$T/repo/graphics/tools/shbake/pso_chunk.sh" <<'STUB'
#!/bin/bash
printf '%s\n' "$1" >> "$PSO_TEST_CALLS"
[ -f "$1" ] || exit 8
STUB
export S2A_PSO_REMOTE=off PSO_PJ=1 PSO_TEST_CALLS=$T/calls
export LC_ALL=C
# 独立长度与期望顺序：11 > 7 = 7 > 2 > 0；相同长度按路径排序。
a="$T/input space/pso.1.mtl4-json"
b="$T/input space/pso.2.mtl4-json"
c="$T/input space/pso.3.mtl4-json"
d="$T/input space/pso.4.mtl4-json"
e="$T/input space/pso.5.mtl4-json"
printf '1234567' > "$a"; printf '12' > "$b"; printf '12345678901' > "$c"
printf '1234567' > "$d"; : > "$e"
printf '%s\n' "$b" "$e" "$d" "$c" "$a" > "$T/list"
printf '%s\n' "$c" "$a" "$d" "$b" "$e" > "$T/expected"
bad=0; n=0
ck() {
  n=$((n + 1))
  if eval "$2"; then echo "通 $n $1"; else echo "不通 $n $1"; bad=$((bad + 1)); fi
}
run() {
  : > "$PSO_TEST_CALLS"; rc=0
  bash "$P" run "$1" "${2:-}" > "$T/out" 2> "$T/err" || rc=$?
}
echo "宿主 stat: $(command -v stat)"
run "$T/list" 5
ck '真实宿主 stat：5 入 5 出、原路径含空格、大小降序和同长次序' '[ "$rc" = 0 ] && cmp -s "$T/expected" "$PSO_TEST_CALLS"'
# BSD 参数协议替身（不代表 Darwin 实测）；GNU 探测失败的 stdout 不得混入清单。
cat > "$T/bin/stat" <<'STUB'
#!/usr/bin/env python3
import os, sys
with open(os.environ['PSO_TEST_STAT_LOG'], 'a') as f:
    f.write(sys.argv[1] + '\n')
if os.environ.get('PSO_TEST_STAT_FAIL') == '1' or sys.argv[1:3] != ['-f', '%z']:
    print('failed stat stdout is not a path')
    sys.exit(1)
print('not-bytes' if os.environ.get('PSO_TEST_STAT_INVALID') == '1' else os.stat(sys.argv[-1]).st_size)
STUB
chmod +x "$T/bin/stat"
export PSO_TEST_STAT_LOG=$T/stat.log
OLDPATH=$PATH; export PATH="$T/bin:$PATH"
run "$T/list" 5
printf -- '-c\n-f\n-c\n-f\n-c\n-f\n-c\n-f\n-c\n-f\n' > "$T/probes"
ck 'BSD 协议回退：逐文件先 GNU 后 BSD，输出仍恰好五条原路径' '[ "$rc" = 0 ] && cmp -s "$T/expected" "$PSO_TEST_CALLS" && cmp -s "$T/probes" "$PSO_TEST_STAT_LOG"'
export PSO_TEST_STAT_FAIL=1
run "$T/list" 5
ck '两种 stat 都失败：非零退出且不启动编片' '[ "$rc" != 0 ] && [ ! -s "$PSO_TEST_CALLS" ]'
unset PSO_TEST_STAT_FAIL
export PSO_TEST_STAT_INVALID=1
run "$T/list" 5
ck 'stat 成功却输出非数字：拒绝污染清单' '[ "$rc" != 0 ] && [ ! -s "$PSO_TEST_CALLS" ]'
unset PSO_TEST_STAT_INVALID
export PATH=$OLDPATH
printf '%s\n' "$a" "$T/input space/pso.99.mtl4-json" > "$T/missing"
run "$T/missing" 2
ck '真实缺文件：前一条正常也不得编部分队列' '[ "$rc" != 0 ] && [ ! -s "$PSO_TEST_CALLS" ]'
run "$T/absent-list"
ck '清单不存在：非零退出且不编片' '[ "$rc" != 0 ] && [ ! -s "$PSO_TEST_CALLS" ]'
# 排序失败不能沿管道被 cut 吞掉；已输出部分内容也不能开始编译。
mkdir -p "$T/fail"
printf '#!/bin/bash\nprintf "11 broken\\n"\nexit 9\n' > "$T/fail/sort"
chmod +x "$T/fail/sort"
export PATH="$T/fail:$OLDPATH"
run "$T/list" 5
ck 'sort 部分输出后失败：非零退出且不编片' '[ "$rc" != 0 ] && [ ! -s "$PSO_TEST_CALLS" ]'
rm "$T/fail/sort"
printf '#!/bin/bash\nprintf "broken\\n"\nexit 9\n' > "$T/fail/cut"
chmod +x "$T/fail/cut"
run "$T/list" 5
ck 'cut 部分输出后失败：非零退出且不编片' '[ "$rc" != 0 ] && [ ! -s "$PSO_TEST_CALLS" ]'
export PATH=$OLDPATH
: > "$T/empty"
run "$T/empty" 0
ck '空清单零片：正常退出且不编片' '[ "$rc" = 0 ] && [ ! -s "$PSO_TEST_CALLS" ]'
run "$T/list" 6
ck '既有应有片数不符拒绝语义不变' '[ "$rc" != 0 ] && [ ! -s "$PSO_TEST_CALLS" ]'
echo "pso_dist_stat：$n 项，失败 $bad"
[ "$bad" = 0 ]
