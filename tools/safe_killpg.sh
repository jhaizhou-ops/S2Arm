# 给进程组发信号的唯一入口（source 本文件）：safe_killpg <信号> <进程组号> [组长命令行须含的字样]
# 10-21 08:40 / 09:21 本机全部用户进程两次被 kill -KILL -- -1：单测 die_nt 按 ps 算出的进程组号是 1（领片进程先退出、父进程变 launchd）。
# 拒绝：组号不是数字、≤ 1、等于调用者自己的组；给了字样 → 组长（pid = 组号）的命令行须含它（清理上一次留下的、不在本进程树里的组用）；
#   没给字样 → 组长须是调用者（$$）的后代。拒绝时打一行原因到标准错误、返回 2，不发信号。门禁 tests/killpg_lint_test.sh 禁止绕开它直接 kill -- -<组>。
safe_killpg() {
  local s=$1 g=$2 m=${3:-} me c p
  case $g in ''|*[!0-9]*) echo "safe_killpg：进程组「${g}」不是数字，不杀" >&2; return 2;; esac
  [ "$g" -gt 1 ] || { echo "safe_killpg：进程组 $g ≤ 1，不杀" >&2; return 2; }
  me=$(ps -o pgid= -p $$ 2> /dev/null | tr -d ' '); [ "$g" != "$me" ] || { echo "safe_killpg：进程组 $g 是调用者自己的组，不杀" >&2; return 2; }
  c=$(ps -ww -o command= -p "$g" 2> /dev/null); [ -n "$c" ] || { echo "safe_killpg：进程组 $g 的组长不在了，不杀" >&2; return 2; }
  if [ -n "$m" ]; then
    case $c in *"$m"*) ;; *) echo "safe_killpg：进程组 $g 的组长「${c:0:80}」不含「${m}」，不杀" >&2; return 2;; esac
  else
    p=$g; while [ -n "$p" ] && [ "$p" -gt 1 ] && [ "$p" != $$ ]; do p=$(ps -o ppid= -p "$p" 2> /dev/null | tr -d ' '); done
    [ "$p" = $$ ] || { echo "safe_killpg：进程组 $g 的组长不是调用者的后代，不杀" >&2; return 2; }
  fi
  kill -"$s" -- -"$g"
}
