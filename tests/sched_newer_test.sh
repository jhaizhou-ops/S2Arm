#!/bin/bash
# 调度器「作业比本调度器新」判断单测（tools/sched.sh newer：从脚本原样取出函数，临时 git 仓库，约 1 秒）：bash tests/sched_newer_test.sh
# 10-29 起因：原生层把没合入分支 fe64a79f0 出的双人成行包登记成正式包，登记冒烟单排在队首 7 分钟、两台测试机都闲着不派——
#   newer 按「作业提交是不是调度器提交的祖先」判，分支提交永远不是，被当成「比本调度器新、留给新调度器」永远跳过，且不打日志。
# 期望（按规则手写：按包代码的 main 基线比——分支提交取它和 origin/main 的分叉点）：main 为 A — B — C，调度器在 B；X 从 A 分出，Y 从 C 分出
#   ① C（main 上、比调度器新）→ 新   ② A（main 上、更老）→ 不新   ③ B（调度器自己）→ 不新
#   ④ X（分支、分叉点 A 早于调度器）→ 不新（旧判断：新、永远不派）   ⑤ Y（分支、分叉点 C 晚于调度器）→ 新
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
eval "$(sed -n '/^newer() {/,/^}/p' "$H/tools/sched.sh")"
declare -f newer > /dev/null || { echo "不通 从 sched.sh 取不出 newer 函数"; exit 1; }
GR=$T/r; git init -q $GR; g() { git -C $GR -c user.name=t -c user.email=t@t "$@"; }
cm() { echo "$1" > $GR/f; g add f; g commit -qm "$1"; g rev-parse HEAD; }
A=$(cm A); B=$(cm B); C=$(cm C); g update-ref refs/remotes/origin/main $C
g checkout -q -b x $A; X=$(cm X); g checkout -q -b y $C; Y=$(cm Y)
OWN=$B
j() { printf 'G=acnh\nCOMMIT=%s\n' "$1" > $T/job; if newer $T/job; then echo 新; else echo 不新; fi; }
ck "① main 上比调度器新的 C → $(j $C)" '[ "$(j $C)" = 新 ]'
ck "② main 上更老的 A → $(j $A)" '[ "$(j $A)" = 不新 ]'
ck "③ 调度器自己的 B → $(j $B)" '[ "$(j $B)" = 不新 ]'
ck "④ 从 A 分出的分支提交 X → $(j $X)（原先判「新」、永远不派）" '[ "$(j $X)" = 不新 ]'
ck "⑤ 从 C 分出的分支提交 Y → $(j $Y)" '[ "$(j $Y)" = 新 ]'
[ $bad = 0 ] && echo "sched_newer 单测全过" || { echo "sched_newer 单测有不通"; exit 1; }
