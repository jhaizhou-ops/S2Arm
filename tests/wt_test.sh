#!/bin/bash
# 工作树换分支安全阀单测（tools/wt.sh，临时仓库，约 3 秒）：bash tests/wt_test.sh
# 期望：有进程当前目录在树里 → busy 退出 0、switch 拒绝（退出 2、列出进程、分支不变）；只是命令行带树路径的进程也算；进程退了 → switch 照切
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
T=$(cd -P "$T" && pwd)
(cd $T && git init -q m && cd m && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m a && git branch b2 && git worktree add -q $T/w -b b1)
W=$T/w; W="$(cd -P $W && pwd)"
# 按事件等假进程就位（10-29 列车线：mini 高负载误红类——原先起完固定睡 0.5 秒：子 shell 还没 cd / exec 时，当前目录与命令行都还是本单测的，判成没人用）：
#   等到它的命令行变成 exec 之后的样子（cd 在 exec 之前，命令行变了 = 当前目录已在树里），上限 60 秒；假进程活 120 秒、判完就杀
uptil() { local i; for i in $(seq 1 600); do [[ "$(ps -o args= -p "$1" 2> /dev/null)" == $2 ]] && return 0; sleep 0.1; done; echo "（60 秒内进程 $1 的命令行没变成「$2」）"; }
(cd $W && exec sleep 120) & P1=$!; uptil $P1 "sleep 120"
bash $H/tools/wt.sh busy $W > $T/o1; r1=$?; bash $H/tools/wt.sh switch b2 $W > $T/o2; r2=$?; br=$(git -C $W branch --show-current)
ck "当前目录在树里的进程 → busy（rc=${r1}）、switch 拒绝（rc=${r2}）、点名进程、分支仍是 ${br}" '[ $r1 = 0 ] && grep -q "^$P1 " $T/o1 && [ $r2 = 2 ] && grep -q "有进程在用" $T/o2 && [ "$br" = b1 ]'
kill $P1; wait $P1 2> /dev/null
bash -c "sleep 120; : $W/x" & P2=$!; uptil $P2 "*$W/x*"
bash $H/tools/wt.sh switch b2 $W > $T/o3; r3=$?; kill $P2; wait $P2 2> /dev/null
ck "命令行带树路径的进程也算在用 → 拒绝（rc=${r3}）" '[ $r3 = 2 ]'
bash $H/tools/wt.sh busy $W > /dev/null; r4=$?; bash $H/tools/wt.sh switch b2 $W > $T/o5; r5=$?; br=$(git -C $W branch --show-current)
ck "没人用 → busy 退出 1（rc=${r4}）、switch 照切到 ${br}（rc=${r5}）" '[ $r4 = 1 ] && [ $r5 = 0 ] && [ "$br" = b2 ]'
rm -rf $T; [ $bad = 0 ] && echo "wt 单测全过" || { echo "wt 单测有不通"; exit 1; }
