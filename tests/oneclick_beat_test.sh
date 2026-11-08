#!/bin/bash
# 一键出包心跳带出「在等什么」（10-29 冷启动演练：主输出 20 分钟只有「刷新进行中」，原因要翻 logs/refresh.log 末行）：bash tests/oneclick_beat_test.sh
#   从 pack/oneclick/oneclick.sh 原样取出 beat 函数（测的是真代码），t / prog_show / prog_dur 打桩，心跳 0.2 秒
# 期望：① 阶段日志末行是「acnh 已有一份刷新在跑（pid 123），等它刷完」→ 心跳行带「在等：acnh 已有一份刷新在跑（pid 123），等它刷完」
#       ② 末行是普通进度（「🟢 改写 3 个模块」）→ 心跳行不带「在等」   ③ 不给日志路径（旧调用）→ 照常心跳、不带「在等」
#       ④ 内存准入排队（审计 #1534 P1-110，tools/mem_admit.sh 写 <S2A_PROGRESS>.wait = 进程号<TAB>排队行）：写它的进程活着 → 心跳带「在等：【排队】…」
#       ⑤ 同一文件、进程号已不在（被杀留下的）→ 不带「在等」
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
eval "$(sed -n '/^beat() {/,/BEAT=\$!; }$/p' "$H/pack/oneclick/oneclick.sh")"
declare -f beat > /dev/null || { echo "不通 从 oneclick.sh 取不出 beat 函数"; exit 1; }
t() { echo "$*"; }; prog_show() { :; }; prog_dur() { echo "${1} 秒"; }; EVF=; export S2A_BEAT_S=0.2
run() {   # run <日志内容或空> [<给不给日志路径>]：起心跳，等到打出第一行再停，输出写 $T/out
  #   按事件等（10-29 列车线：原先固定睡 0.8 秒——mini 高负载下第一行来不及打出，三条全空红；TERM 落在心跳子 shell 忙时它没退，wait 挂满 600 秒）：
  #   等第一行最多 30 秒；停时先 TERM，5 秒内没退再 KILL，不无限 wait
  local i; printf '%s\n' "$1" > $T/stage.log; BEAT=; : > $T/out
  if [ "${2:-1}" = 1 ]; then beat 刷新 $T/stage.log > $T/out; else beat 刷新 > $T/out; fi
  for i in $(seq 1 300); do [ -s $T/out ] && break; sleep 0.1; done
  kill "$BEAT" 2> /dev/null; for i in $(seq 1 50); do kill -0 "$BEAT" 2> /dev/null || break; sleep 0.1; done
  kill -0 "$BEAT" 2> /dev/null && { echo "（心跳子 shell TERM 后 5 秒没退，KILL）"; kill -9 "$BEAT" 2> /dev/null; }; wait "$BEAT" 2> /dev/null; }
run 'acnh 已有一份刷新在跑（pid 123），等它刷完'
ck "① 末行是在等别的刷新 → 心跳带「在等」与两个数（$(head -1 $T/out)）" 'grep -q "刷新进行中.*在等：acnh 已有一份刷新在跑（pid 123），等它刷完" $T/out'
run '🟢 acnh 改写 3 个模块（19 秒）'
ck "② 末行是普通进度 → 不带「在等」（$(head -1 $T/out)）" 'grep -q "刷新进行中" $T/out && ! grep -q "在等" $T/out'
run 'acnh 已有一份刷新在跑（pid 123），等它刷完' 0
ck "③ 不给日志路径 → 照常心跳、不带「在等」（$(head -1 $T/out)）" 'grep -q "刷新进行中" $T/out && ! grep -q "在等" $T/out'
export S2A_PROGRESS=$T/progress.tsv
sleep 60 & LIVE=$!
printf '%s\t%s\n' "$LIVE" '【排队】mem_admit dsh/acnh：需 7.8 GB（生键·类别下限），差 1.2 GB；等：dsh/mk8(pid 9,8.0 GB,8 核)' > "$S2A_PROGRESS.wait"
run '🟢 acnh 改写 3 个模块（19 秒）'
ck "④ 内存准入排队、写它的进程活着 → 心跳带「在等：【排队】…」（$(head -1 $T/out)）" 'grep -q "刷新进行中.*在等：【排队】mem_admit dsh/acnh：需 7.8 GB" $T/out'
kill $LIVE 2> /dev/null; wait $LIVE 2> /dev/null
run '🟢 acnh 改写 3 个模块（19 秒）'
ck "⑤ 同一文件、进程号已不在 → 不带「在等」（$(head -1 $T/out)）" 'grep -q "刷新进行中" $T/out && ! grep -q "在等" $T/out'
unset S2A_PROGRESS
[ $bad = 0 ] && echo "oneclick_beat 单测全过" || { echo "oneclick_beat 单测有不通"; exit 1; }
