#!/bin/bash
# 进程间互斥锁（审计 P1-27，11-02 出包线）：出包锁 / 刷新锁 / 产物根提交锁 / 登记锁等共用这一份。source 后用：
#   plock_take <锁文件> <等待上限秒（0 = 只试一次）> → 0 取到（PLOCK_PID = 持锁小进程 pid，调用方当场存进自己的变量：同一 shell 里可能先后拿几把）；
#                                                   1 到上限没取到；2 起不了持锁进程 / 锁文件打不开（报红，不当被占空等）
#   plock_release <持锁小进程 pid>                                → 放锁（结束持锁小进程，内核随之放锁）
#   plock_holder <锁文件>                                         → 现持锁者 pid（只作「谁在用」的提示，不是判据）
# 互斥交给内核文件锁：tools/flock_hold.py（与设备锁 tools/devlock.sh 同一份）。持锁者 = 调用方的 BASHPID（并行段子 shell 各算各的），
#   持锁者退出（含 kill -9）持锁小进程随即退出、内核放锁；锁文件常驻不删。
# 取代原先各处「mkdir 锁目录 → 写 pid；pid 空 / 进程已死就 rm -rf」：mkdir 成功到写 pid 之间是空 pid、读 pid → 判死 → 删锁之间别人可能已接手，
#   两个等待者都看见死 pid 时，一个写上新 pid、另一个仍按旧读数删掉新锁（同一款两路出包 / 两次提交根同时改同一棵产物）
PLOCK_PY=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/flock_hold.py
PLOCK_PID=
plock_take() {
  local f=${1:?锁文件} max=${2:-0} t0=$SECONDS p rc me=${BASHPID:-$$}
  mkdir -p "$(dirname "$f")" || return 2
  while :; do
    p=$(python3 "$PLOCK_PY" "$f" "$me" take plock_hold 2> /dev/null); rc=$?
    if [ $rc = 0 ]; then PLOCK_PID=$p; printf '%s\n' "$me" > "$f.holder" 2> /dev/null; return 0; fi
    [ $rc = 1 ] || { echo "【红】进程锁：持锁小进程起不来（返回 ${rc}，锁文件 ${f}）" >&2; return 2; }
    [ $((SECONDS - t0)) -lt "$max" ] || return 1
    sleep "${PLOCK_POLL_S:-1}"
  done
}
plock_holder() { cat "${1:?锁文件}.holder" 2> /dev/null; }
plock_release() {
  local p=$1 i; [ -n "$p" ] || return 0
  ps -o command= -p "$p" 2> /dev/null | grep -q plock_hold || return 0   # 只结束自己起的持锁小进程（pid 复用时不误杀别的）
  kill -TERM "$p" 2> /dev/null || true
  for i in $(seq 1 100); do kill -0 "$p" 2> /dev/null || return 0; sleep 0.02; done
  echo "【红】进程锁：持锁小进程 pid $p 收到 TERM 2 秒仍未退出" >&2; return 0
}
