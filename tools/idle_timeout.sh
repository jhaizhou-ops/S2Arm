#!/bin/bash
# 按「有没有进展」收掉卡死的命令（11-04 合入运维线）：idle_timeout.sh <无进展上限秒> <硬上限秒> <盯的文件或目录>… -- <命令…>
#   盯的东西（文件，或目录下第一层文件）最近修改时间离现在超过「无进展上限」，或总时长超过「硬上限」，就 TERM 命令（10 秒后仍在则 KILL），退出 124；
#   否则退出码同命令。替代套在门禁外面的固定墙钟 timeout：令牌 / 满核槽 / 显卡独占排队期间门禁仍在打心跳与排队行（日志在长），不该被当成卡死收掉
#   （11-04 contrib_check 2700 秒与 remote.sh 整份 --timeout 把排队算进去，多份自检整份 0 结论、已出结论也丢）。
# 结构（11-05）：主流程直接 wait 命令，命令一结束立刻返回；无进展 / 硬上限由旁路看门进程判（原先主循环每 IDLE_TIMEOUT_POLL_S 秒醒一次，
#   命令早结束了也要睡满一轮，remote_test 三十来次 remote.sh 叠出几分钟，mini 上跑满 600 秒）。看门进程的标准输出 / 错误不接调用方的管道
set -u
IDLE=${1:?无进展上限秒}; HARD=${2:?硬上限秒}; shift 2; W=()
while [ $# -gt 0 ] && [ "$1" != -- ]; do W+=("$1"); shift; done
[ "${1:-}" = -- ] || { echo "用法：idle_timeout.sh <无进展秒> <硬上限秒> <盯的文件或目录>… -- <命令…>" >&2; exit 2; }; shift
if [ "$(uname)" = Darwin ]; then MT=(stat -f %m); else MT=(stat -c %Y); fi   # 修改时间（秒）：BSD 与 GNU stat 格式串不同
newest() { local w m n=0; for w in "${W[@]}"; do
    if [ -d "$w" ]; then m=$(find "$w" -maxdepth 1 -type f -exec "${MT[@]}" {} + 2> /dev/null | sort -n | tail -1); else m=$("${MT[@]}" "$w" 2> /dev/null); fi
    [ "${m:-0}" -gt $n ] && n=$m; done; echo $n; }
stopc() { pkill -TERM -P "$1" 2> /dev/null; kill -TERM "$1" 2> /dev/null; for i in $(seq 1 10); do kill -0 "$1" 2> /dev/null || return 0; sleep 1; done; kill -KILL "$1" 2> /dev/null; }
R=$(mktemp "${TMPDIR:-/tmp}/idle_timeout.XXXXXX")   # 看门进程判了超时就把原因写这里
"$@" <&0 & P=$!; t0=$(date +%s)   # <&0：非交互 bash 的后台命令缺省把标准输入换成 /dev/null；remote.sh 靠 ssh 标准输入判本机存活，换掉后远端门禁 10 秒就自收（11-05）
( while sleep "${IDLE_TIMEOUT_POLL_S:-10}"; kill -0 $P 2> /dev/null; do
    now=$(date +%s); n=$(newest); [ "$n" -lt $t0 ] && n=$t0; why=
    if [ $((now - t0)) -ge "$HARD" ]; then why="总时长 $((now - t0)) 秒到硬上限 ${HARD}"; elif [ $((now - n)) -ge "$IDLE" ]; then why="$((now - n)) 秒没有新输出（无进展上限 ${IDLE}）"; fi
    [ -n "$why" ] || continue
    echo "$why" > "$R"; stopc $P; exit 0
  done ) > /dev/null 2>&1 < /dev/null & WD=$!
# 自己被 TERM / INT（列车停、换副本：train.sh 只 kill 门禁外层这一个进程）→ 转给命令及其子进程再退 143，不留孤儿门禁占 mini（11-05）
trap 'kill $WD 2> /dev/null; stopc $P; rm -f "$R"; exit 143' TERM INT
wait $P; rc=$?
pkill -P $WD 2> /dev/null; kill $WD 2> /dev/null; wait $WD 2> /dev/null
if [ -s "$R" ]; then echo "【红】idle_timeout：$(cat "$R")，收掉" >&2; rm -f "$R"; exit 124; fi
rm -f "$R"; exit $rc
