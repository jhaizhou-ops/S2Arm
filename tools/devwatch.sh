#!/bin/bash
# 真机执行器硬上限看门狗（tools/dev_run.sh source）：arm <秒> / disarm；用到调用方的 ${O}（局目录）与 WD。
#   到点先 TERM 本进程与直接子进程（本进程的 TERM 处理 oncap 收局、放锁、判红）；再过 S2A_CAP_GRACE_S（缺省 30）秒本进程还在 →
#   往 run.log 与标准输出各写一行结论（调度读 RESULT），按下面的范围 KILL。
#   11-04 能耗线现场（巫师3 测试机1 out_1104111555）：命令替换里写 here-doc 的子进程卡在写管道、挂到 1 号进程下还攥着执行器的输出，
#   主进程停在等命令替换读完（bash 此时推迟 TERM 处理），只发 TERM 的旧看门狗让局卡了 89 分钟、占着设备锁。
#   强杀范围：本局主进程，加上 fd1 / fd2 与它是同一个管道写端、或往它正在读的管道里写的进程（子孙、挂到 1 号下的孤儿——正是它们攥着管道让调用方 / 主进程等不到结束；调用方握的是读端，认不进来），
#   排除看门狗自己和主进程的祖先（调用方若在同一个命令替换里有子 shell，也握着这个写端）。主进程输出不是管道（写文件）时只杀主进程。
#   不按进程名 / 进程组 / 环境变量认（macOS ps -E 读不到系统二进制的环境，11-04 实测 sleep 读不到）
devwatch_kill() {   # devwatch_kill <主进程 pid>
  local main=$1 me=${BASHPID:-$$} w r anc q p cand
  # w：主进程 fd1 / fd2 的管道写端；r：主进程握着的全部管道端（含它正在读的命令替换管道的读端）
  w=$(lsof -a -p "$main" -d 1,2 -F td 2> /dev/null | awk '/^t/ { t = substr($0, 2) } /^d/ { if (t == "PIPE") printf " %s", substr($0, 2) }')
  r=$(lsof -a -p "$main" -F td 2> /dev/null | awk '/^t/ { t = substr($0, 2) } /^d/ { if (t == "PIPE") printf " %s", substr($0, 2) }')
  anc=" $me "; q=$main
  while :; do q=$(ps -o ppid= -p "$q" 2> /dev/null); q=${q// /}; [ -n "$q" ] && [ "$q" -gt 1 ] || break; anc="$anc$q "; done
  # 候选：fd1 / fd2 是同一个写端（与主进程共享输出），或写端的对端是主进程握着的管道（往主进程正在读的管道里写）。
  #   先列再杀：主进程一死，读端关闭，孤儿那根管道的对端标识就没了
  cand=; [ -n "${r// /}" ] && cand=$(lsof -u "$(id -u)" -a -d 1,2 -F ptdn 2> /dev/null | awk -v w="$w " -v r="$r " '/^p/ { p = substr($0, 2) } /^t/ { t = substr($0, 2) } /^d/ { d = substr($0, 2) }
      /^n/ { if (t != "PIPE") next; n = substr($0, 2); sub(/^->/, "", n); if ((w != " " && index(w, " " d " ")) || index(r, " " n " ")) print p }' | sort -u)
  kill -KILL "$main" 2> /dev/null
  for p in $cand; do
    case "$anc" in *" $p "*) continue;; esac
    kill -KILL "$p" 2> /dev/null
  done
}
arm() {
  ( sleep "$1"; kill -TERM $$ 2> /dev/null; pkill -TERM -P $$ 2> /dev/null
    sleep "${S2A_CAP_GRACE_S:-30}"; kill -0 $$ 2> /dev/null || exit 0
    echo "[$(date +%T)] 【红】硬上限到点 TERM 后 ${S2A_CAP_GRACE_S:-30} 秒本局仍不退（TERM 被推迟 / 子进程不退），强杀本局全部进程" >> "$O/run.log"
    echo "RESULT=red out=$O reason=硬上限到点后进程不退，强杀"
    devwatch_kill $$ ) & WD=$!; disown "$WD"; }   # 到点先标记本进程、再杀子进程让前台命令返回；宽限后仍在就强杀
# 收看门狗：先记下它的 sleep、先杀子 shell、再杀 sleep——反过来的话 sleep 一死子 shell 就往下执行「kill -TERM 本进程」，被误判成外部停局；
# 不杀 sleep 则孤儿 sleep 占着调用方的输出管道（$(…) 要等满 900 秒）
disarm() { [ -n "${WD:-}" ] || return 0; local k; k=$(pgrep -P "$WD" 2>/dev/null); kill -KILL "$WD" 2>/dev/null; [ -z "$k" ] || kill $k 2>/dev/null; WD=; }
