#!/bin/bash
# 超时杀整棵进程树单测（tools/bin/timeout perl 版 + tools/toolchain.sh 把它放到 PATH 最前，约 15 秒）：bash tests/timeout_tree_test.sh
#   ① 嵌套（外层 2 秒、内层 100 秒，内层在后台 / 前台各一次）：外层到点后内层命令全没了，外层退出 124
#   ② -k 1 -s INT：到点发 INT；命令忽略 INT 时 1 秒后 KILL，退出 124；不认的选项退出 125
#   ③ source tools/toolchain.sh 后 command -v timeout = 仓库 tools/bin/timeout（工具链不全时 source 返回非 0 也一样，PATH 在最前就设）
#   ④ 反证：系统有 GNU timeout 时，同一嵌套用 GNU 的会留下内层（10-28 direct_lib 孤儿写盘 2 小时的来源）——只打读数，不判（没装 coreutils 的机器跳过）
set -u; R=$(cd "$(dirname "$0")/.." && pwd); TO=$R/tools/bin/timeout; T=$(mktemp -d); trap 'pkill -f "sleep 9[0-9]$$" 2> /dev/null; rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
alive() { pgrep -f "sleep $1" > /dev/null; }
printf 'timeout 100 sleep 91%s &\nwait\n' $$ > $T/bg.sh; printf 'timeout 100 sleep 92%s\n' $$ > $T/fg.sh
PATH=$R/tools/bin:$PATH $TO 2 bash $T/bg.sh; r=$?; sleep 3
ck "① 后台嵌套：外层到点退出 124、内层 sleep 没了（rc=${r}）" '[ $r = 124 ] && ! alive 91$$'
PATH=$R/tools/bin:$PATH $TO 2 bash $T/fg.sh; r=$?; sleep 3
ck "① 前台嵌套：外层到点退出 124、内层 sleep 没了（rc=${r}）" '[ $r = 124 ] && ! alive 92$$'
s=$SECONDS; $TO -k 1 -s INT 1 bash -c 'trap "" INT; sleep 93'"$$"; r=$?; d=$((SECONDS - s)); sleep 1
# 用时只判「没等命令自己睡完 93 秒」（< 60）：10-29 列车线 mini 高负载误红类——原判 ≤ 4 秒，perl 起步 + 1 秒到点 + 1 秒宽限在负载下就会超
ck "② -k 1 -s INT：忽略 INT 的命令 1 秒后被 KILL、退出 124、约 2 秒（rc=${r}，${d} 秒，< 60：没等它睡满 93 秒）" '[ $r = 124 ] && [ $d -lt 60 ] && ! alive 93$$'
$TO --bogus 1 true 2> /dev/null; r=$?
ck "② 不认的选项退出 125（rc=${r}）" '[ $r = 125 ]'
# ①b 嵌套里孙进程忽略 TERM（#814 F-timeout-nest-kill）：外层到点 TERM 后，内层 timeout 被外层 KILL 来不及转发，孙进程在内层自己的组里 → 外层退出后不许留下
printf 'timeout 100 bash -c "trap \\"\\" TERM; sleep 95%s" &\nwait\n' $$ > $T/ign.sh
PATH=$R/tools/bin:$PATH $TO 2 bash $T/ign.sh; r=$?; sleep 3
ck "①b 嵌套孙进程忽略 TERM：外层到点退出 124、孙进程也没了（rc=${r}）" '[ $r = 124 ] && ! alive 95$$'
w=$(cd "$R" && env -u S2A_TC_RESOLVED bash -c '. tools/toolchain.sh > /dev/null 2>&1; command -v timeout')
ck "③ source toolchain.sh 后 timeout = 仓库 perl 版（实得 ${w}）" '[ "$w" = "$R/tools/bin/timeout" ]'
G=$(PATH=$(echo "$PATH" | tr ':' '\n' | grep -vxF "$R/tools/bin" | paste -sd: -) command -v timeout)
if [ -n "$G" ] && "$G" --version 2> /dev/null | grep -q GNU; then
  printf '%s 100 sleep 94%s &\nwait\n' "$G" $$ > $T/gnu.sh; "$G" 2 bash $T/gnu.sh; sleep 2
  alive 94$$ && echo "④ 反证读数：GNU timeout 嵌套时内层仍活（${G}），所以出包链要用仓库 perl 版" || echo "④ 反证读数：GNU timeout 这次没留内层"; pkill -f "sleep 94$$"
else echo "④ 跳过：本机没有 GNU timeout"; fi
[ $bad = 0 ] && echo "timeout_tree 单测全过" || { echo "timeout_tree 单测有不通"; exit 1; }
