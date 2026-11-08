#!/bin/bash
# 门禁覆盖：tools/idle_timeout.sh
# tools/idle_timeout.sh 单测（11-04 合入运维线）：期望值按规则手写（轮询 1 秒）
#   ① 每秒往盯的文件写、跑 6 秒，无进展上限 3 → 不收，退出码原样（7）；② 10 秒不出声，无进展上限 3 → 124，且 < 8 秒收掉
#   ③ 一直在写但跑 10 秒，硬上限 4 → 124；④ 盯目录：目录里每秒新建文件、跑 6 秒，无进展上限 3 → 不收（0）；⑤ 正常结束 → 0
#   ⑦ 标准输入原样传给命令（不是 /dev/null）；⑥ idle_timeout 自己收到 TERM → 退 143，命令起的子进程也被收掉（列车 trap 只 kill 门禁外层一个进程）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d "${TMPDIR:-/tmp}/t_idle.XXXXXX"); trap 'rm -rf "$T"' EXIT; bad=0; export IDLE_TIMEOUT_POLL_S=1
chk() { if [ "$2" = "$3" ]; then echo "🟢 $1"; else echo "🔴 $1：期望「$2」→ 真结果「$3」"; bad=1; fi; }
I=$H/tools/idle_timeout.sh
bash $I 3 60 $T/a.log -- bash -c "for i in 1 2 3 4 5 6; do echo x >> $T/a.log; sleep 1; done; exit 7" 2> /dev/null; chk "① 一直有进展（6 秒、上限 3）→ 不收，退出码 7" 7 $?
s=$SECONDS; bash $I 3 60 $T/b.log -- sleep 10 2> /dev/null; r=$?; d=$((SECONDS - s)); chk "② 10 秒无进展（上限 3）→ 124 且 8 秒内收掉" "124 是" "$r $([ $d -lt 8 ] && echo 是 || echo 否:$d)"
bash $I 30 4 $T/c.log -- bash -c "for i in \$(seq 1 10); do echo x >> $T/c.log; sleep 1; done" 2> /dev/null; chk "③ 有进展但到硬上限 4 → 124" 124 $?
mkdir -p $T/d; bash $I 3 60 $T/d -- bash -c "for i in 1 2 3 4 5 6; do : > $T/d/f\$i; sleep 1; done" 2> /dev/null; chk "④ 盯目录、目录里不断有新文件 → 不收（0）" 0 $?
bash $I 3 60 $T/e.log -- true; chk "⑤ 正常结束 → 0" 0 $?
bash $I 30 60 $T/f.log -- bash -c "sleep 50 & echo \$! > $T/f.kid; wait" 2> /dev/null & ip=$!
for i in $(seq 1 50); do [ -s $T/f.kid ] && break; sleep 0.1; done; kid=$(cat $T/f.kid 2> /dev/null); kill -TERM $ip; wait $ip; r=$?; sleep 1
chk "⑥ 自己收到 TERM（列车停）→ 退 143、命令的子进程也收掉" "143 收掉" "$r $(kill -0 ${kid:-999999} 2> /dev/null && echo 还在 || echo 收掉)"
echo 存活 | bash $I 3 60 $T/g.log -- bash -c "read x; echo \"\$x\" > $T/g.out"; chk "⑦ 标准输入原样传给命令（remote.sh 靠 ssh 标准输入判本机存活）" 存活 "$(cat $T/g.out 2> /dev/null)"
s0=$SECONDS; IDLE_TIMEOUT_POLL_S=10 bash $I 30 60 $T/h.log -- sleep 1; d=$((SECONDS - s0)); chk "⑨ 命令一结束立刻返回（命令 1 秒、轮询 10 秒也不睡满一轮）" 是 "$([ $d -lt 4 ] && echo 是 || echo "否:${d}秒")"
# ⑧ 门禁心跳不拖住外层命令替换（11-05：心跳的 sleep 开着门禁的标准输出，$(bash tools/gate.sh) 每份白等至多 GATE_BEAT_S 秒）：
#   临时仓库只有一个秒过的钩子，GATE_BEAT_S=30 → $(…) 在 20 秒内返回
G=$T/g; mkdir -p $G/tools $G/h; cp $H/tools/gate.sh $G/tools/; (cd $G && git init -q && git config user.email t@t && git config user.name t && echo 'echo 过 → 过' > h/gate.sh && git add -A && git commit -qm a)
s0=$SECONDS; o=$(cd $G && env -u GATE_LAYER -u GATE_TIER GATE_BEAT_S=30 GATE_TIER=full S2A_GATE_CPU_IDLE_MIN=0 bash tools/gate.sh 2>&1); d=$((SECONDS - s0))
chk "⑧ 心跳不拖住 \$(门禁)：GATE_BEAT_S=30 时 20 秒内返回" 是 "$([ $d -lt 20 ] && echo 是 || echo "否:${d}秒")"
[ $bad = 0 ] && echo "idle_timeout 单测全过" || { echo "idle_timeout 单测有红"; exit 1; }
