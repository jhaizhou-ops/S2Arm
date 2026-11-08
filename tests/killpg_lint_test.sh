#!/bin/bash
# 进程组信号守卫单测（tools/safe_killpg.sh + tools/killpg_lint.py，约 5 秒）：bash tests/killpg_lint_test.sh
# 10-21 08:40 / 09:21 本机全部用户进程两次被 kill -KILL -- -1（单测 die_nt 按 ps 算出组号 1）。期望（按规则手写）：
#   ① 全仓（tools/safe_killpg.sh 本身、扫描器 tools/killpg_lint.py、本单测的坏写法夹具与 compat/tree 除外）没有绕开 safe_killpg 直接给进程组发信号的写法
#   ② 正对照：出事那行与 remote.sh 旧写法、kill -9 -1、pkill -g、os.killpg 都报；kill -0 / kill $pid / safe_killpg / pkill -P 不报
#   ③ safe_killpg 拒绝：组号 1、非数字、调用者自己的组、组长不是后代（没给字样）、组长命令行不含字样——都返回 2 且一次 kill 都不调（kill 换成记录函数，不会真发）
#   ④ safe_killpg 照杀：本测试起的后台作业组（后代）、给了对的字样的受控非后代组
# 不通时完整输出（含 Python 段的回溯）另存一份：11-06 本机 10 次红 1 次，调用方把输出丢了，没法定因。外层把整次输出写进临时文件，不通就留在
#   ${S2A_TEST_FAIL_DIR:-$TMPDIR}/killpg_lint_fail_<时刻>_<pid>.log 并打出路径；通过就删
if [ -z "${KP_INNER:-}" ]; then
  kl=$(mktemp "${TMPDIR:-/tmp}/killpg_lint_out.XXXXXX"); KP_INNER=1 bash "$0" "$@" > "$kl" 2>&1; kr=$?; cat "$kl"
  if [ $kr != 0 ]; then kd=${S2A_TEST_FAIL_DIR:-${TMPDIR:-/tmp}}; mkdir -p "$kd"; kf=$kd/killpg_lint_fail_$(date +%m%d-%H%M%S)_$$.log; mv "$kl" "$kf"; echo "不通时完整输出已留：$kf"; else rm -f "$kl"; fi
  exit $kr
fi
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0; trap 'if [ -e "$T/killpg-cleanup-failed" ]; then echo "保留清理失败现场：$T" >&2; else rm -rf "$T"; fi' EXIT
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
cd "$H" || exit 1
git ls-files -z | python3 -c '
import sys
for f in sys.stdin.read().split("\0"):
    if not f or f.startswith("compat/tree/") or f in ("tools/safe_killpg.sh", "tools/killpg_lint.py", "tests/killpg_lint_test.sh") or f.endswith((".md",".png",".jpg",".bin",".zst",".rec",".metallib")): continue
    try: b = open(f, "rb").read(400000)
    except OSError: continue
    if b"\0" not in b: print(f)' > $T/files
o=$(python3 tools/killpg_lint.py $(cat $T/files) 2>&1); n=$(grep -c . <<< "$o")
ck "① 全仓 $(wc -l < $T/files | tr -d ' ') 个文本文件里绕开 safe_killpg 给进程组发信号的写法 0 处（命中：${o:0:300}）" '[ -z "$o" ]'
cat > $T/bad.sh <<'X'
sp=\$(ps -o ppid= -p \$PPID | tr -d ' '); kill -KILL -- -"\$(ps -o pgid= -p "\$sp" | tr -d ' ')"; sleep 5
then kill -TERM -- -\$p 2> /dev/null || true; sleep 2; kill -KILL -- -\$p 2> /dev/null || true
( cat > /dev/null; kill -TERM -- -\$p 2> /dev/null ) &
kill -- -\$w 2> /dev/null; rm -f x
kill -9 -1
kill -TERM -"$pg"
pkill -g 123
os.killpg(pg, 9)
X
cat > $T/good.sh <<'X'
kill -0 "$p" 2> /dev/null
kill "$pid"; kill -TERM $p
safe_killpg TERM $p 'S2A_REMOTE_NAME=x '
pkill -P $$
X
nb=$(python3 tools/killpg_lint.py $T/bad.sh | grep -c .); ng=$(python3 tools/killpg_lint.py $T/good.sh | grep -c .)
ck "② 正对照：坏写法 8 行全报（报 ${nb}）、好写法 0 行报（报 ${ng}）" '[ "$nb" = 8 ] && [ "$ng" = 0 ]'
. tools/safe_killpg.sh
PY='import os,sys,time; os.setsid(); open(sys.argv[1], "w").write(str(os.getpid())); time.sleep(20)'   # 孤儿组组长：自己写 pid（不用 pgrep 找）
( kill() { echo "kill $*" >> $T/calls; }; : > $T/calls
  safe_killpg KILL 1 2> $T/e1; r1=$?; safe_killpg KILL abc 2> /dev/null; r2=$?; safe_killpg KILL "$(ps -o pgid= -p $$ | tr -d ' ')" 2> /dev/null; r3=$?
  # 等孤儿组组长写 pid 最多 30 秒（同④；原 5 秒，机器忙时 python 起不来就把孤儿组判成「空」）
  (python3 -c "$PY" $T/o3.pid &); for i in $(seq 1 300); do [ -s $T/o3.pid ] && break; sleep 0.1; done; og=$(cat $T/o3.pid 2> /dev/null)
  safe_killpg KILL "$og" 2> /dev/null; r4=$?; safe_killpg KILL "$og" 'NOT_THERE_MARK' 2> /dev/null; r5=$?
  echo "$r1 $r2 $r3 $r4 $r5 $(grep -c . $T/calls) ${og:-空}" > $T/refuse; kill -0 "$og" 2> /dev/null; /bin/kill -KILL "$og" 2> /dev/null )
read -r r1 r2 r3 r4 r5 nc og3 < $T/refuse
ck "③ 拒绝：组号 1 / 非数字 / 自己的组 / 孤儿组没给字样 / 字样不对 → 都返回 2（${r1} ${r2} ${r3} ${r4} ${r5}）、kill 一次没调（${nc}）、组号 1 有原因行、孤儿组确实找到了（${og3}）" '[ "$r1$r2$r3$r4$r5" = 22222 ] && [ "$nc" = 0 ] && grep -q "≤ 1" $T/e1 && [ "$og3" != 空 ]'
# 外层 $$ 活到④受控清理完成；否则 helper 的后代检查及临时目录会先失效。
kp_outer_signal=0
kp_outer_int=$(trap -p INT); kp_outer_term=$(trap -p TERM)
trap 'kp_outer_signal=130' INT
trap 'kp_outer_signal=143' TERM
# ④ 后代组：只由本 shell 的作业表判断完成，wait 核对真实 TERM 状态。
# 固定 sleep 后 kill -0 会把合法的延迟完成判红；夹具不得在截止内自然退出。
(
  kp_child= kp_interrupted=0
  kp_ready_file="$T/kp-child.ready"
  kp_active() {
    local p
    for p in $(jobs -pr; jobs -ps); do [ "$p" = "$kp_child" ] && return 0; done
    return 1
  }
  kp_ready() { [ -s "$kp_ready_file" ] && [ "$(cat "$kp_ready_file")" = "$kp_child" ]; }
  kp_done() { ! kp_active; }
  kp_wait() {
    local label=$1 seconds=$2 deadline; shift 2
    deadline=$(python3 -c 'import sys,time; print(time.monotonic()+float(sys.argv[1]))' "$seconds") || return 1
    until "$@"; do
      python3 - "$deadline" <<'CLOCK'
import sys, time
if time.monotonic() >= float(sys.argv[1]):
    raise SystemExit(1)
time.sleep(0.05)
CLOCK
      if [ $? != 0 ]; then echo "不通 ④ 后代组 ${label}：${seconds} 秒截止" >&2; return 1; fi
    done
  }
  kp_cleanup() {
    trap '' INT TERM
    [ -n "$kp_child" ] || return 0
    if kp_active; then
      # 尚未 exec 的子 shell 也在本作业表且是后代；不用宽字样或猜组号。
      safe_killpg KILL "$kp_child" || {
        : > "$T/killpg-cleanup-failed"; echo "④ 回收拒绝，保留现场：${T}（自建组 ${kp_child}）" >&2; return 1;
      }
      kp_wait 回收 5 kp_done || {
        : > "$T/killpg-cleanup-failed"; return 1;
      }
    fi
    wait "$kp_child" 2>/dev/null || :
    kp_child=
  }
  trap 'kp_rc=$?; kp_cleanup || kp_rc=1; exit "$kp_rc"' EXIT
  # spawn → $! 登记期间只记中断；登记后才退出，避免清理漏掉刚 fork 的作业。
  trap 'kp_interrupted=130' INT
  trap 'kp_interrupted=143' TERM
  set -m
  (trap - EXIT; exec python3 -c '
import os, pathlib, sys, time
pathlib.Path(sys.argv[1]).write_text(str(os.getpid()))
time.sleep(120)
' "$kp_ready_file" "safe-killpg-child-$BASHPID") > "$T/kp-child.log" 2>&1 & kp_child=$!
  set +m
  [ "$kp_interrupted" = 0 ] || exit "$kp_interrupted"
  trap 'exit 130' INT
  trap 'exit 143' TERM
  kp_wait 就绪 30 kp_ready || exit 1
  safe_killpg TERM "$kp_child"; kp_signal_rc=$?
  [ "$kp_signal_rc" = 0 ] || { echo "不通 ④ 后代组 TERM 被拒（rc ${kp_signal_rc}）" >&2; exit 1; }
  kp_wait TERM完成 30 kp_done || exit 1
  wait "$kp_child"; kp_status=$?
  kp_child=
  [ "$kp_status" = 143 ] || { echo "不通 ④ 后代组退出 ${kp_status}，期望 TERM 的 143" >&2; exit 1; }
  echo '通 ④ 后代组：真实 TERM 完成，wait=143'
)
rc=$?; [ "$rc" = 0 ] || bad=1
[ "$kp_outer_signal" = 0 ] || exit "$kp_outer_signal"
# ④ marker 分支：目标是调用 helper 的 Bash 的非后代，不伪称真实孤儿。
# Python 直接拥有并回收它，因此可核信号退出，且不依赖系统孤儿收养/回收时机。
python3 - "$H" "$T" <<'PYGROUP'
import pathlib, signal, subprocess, sys, time, uuid
root, temp = map(pathlib.Path, sys.argv[1:])
marker = "safe-killpg-sibling-" + uuid.uuid4().hex
ready = temp / "kp-sibling.ready"
child = None
blocked = {signal.SIGINT, signal.SIGTERM}

def interrupted(signum, _frame):
    raise SystemExit(128 + signum)

for sig in blocked:
    signal.signal(sig, interrupted)

def group_signal(sig, required=None):
    args = ["bash", "-c", 'source "$1/tools/safe_killpg.sh"; safe_killpg "$2" "$3" "${4:-}"',
            "killpg-test", str(root), sig, str(child.pid)]
    if required is not None:
        args.append(required)
    return subprocess.run(args, capture_output=True, text=True, timeout=30)

try:
    # 信号延后到 Popen 完成登记；子进程 exec 后在 ready 前解除继承的屏蔽。
    previous = signal.pthread_sigmask(signal.SIG_BLOCK, blocked)
    try:
        with (temp / "kp-sibling.log").open("wb") as child_log:
            child = subprocess.Popen([sys.executable, "-c", '''
import os, pathlib, signal, sys, time
signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGINT, signal.SIGTERM})
pathlib.Path(sys.argv[1]).write_text(str(os.getpid()))
time.sleep(120)
''', str(ready), marker], start_new_session=True, stdout=child_log, stderr=subprocess.STDOUT)
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous)
    deadline = time.monotonic() + 30
    while not (ready.exists() and ready.read_text() == str(child.pid)):
        if child.poll() is not None:
            raise AssertionError(f"④ 非后代组 ready 前退出：{child.returncode}")
        if time.monotonic() >= deadline:
            raise AssertionError("④ 非后代组就绪：30 秒截止")
        time.sleep(0.05)
    rejected = group_signal("TERM")
    assert rejected.returncode == 2 and child.poll() is None, (
        "④ 非后代组无 marker 应拒绝且仍活着", rejected.returncode, rejected.stderr)
    accepted = group_signal("TERM", marker)
    assert accepted.returncode == 0, ("④ 非后代组 marker TERM 被拒", accepted.stderr)
    try:
        status = child.wait(timeout=30)
    except subprocess.TimeoutExpired as exc:
        raise AssertionError("④ 非后代组 TERM 完成：30 秒截止") from exc
    assert status == -signal.SIGTERM, f"④ 非后代组退出 {status}，期望 {-signal.SIGTERM}"
    print("通 ④ 非后代组：无 marker 拒绝，匹配 marker 后真实 TERM 完成，wait=-15")
finally:
    # 二次中断不截断已开始的有界清理；不绕过 helper 的身份拒绝。
    signal.pthread_sigmask(signal.SIG_BLOCK, blocked)
    if child is not None and child.poll() is None:
        try:
            killed = group_signal("KILL", marker)
            if killed.returncode != 0:
                raise RuntimeError(f"helper 拒绝回收：{killed.stderr}")
            child.wait(timeout=5)
        except (OSError, subprocess.TimeoutExpired, RuntimeError) as exc:
            (temp / "killpg-cleanup-failed").touch()
            raise RuntimeError(f"④ 回收失败，保留现场 {temp}，自建组 {child.pid}: {exc}") from exc
PYGROUP
rc=$?; [ "$rc" = 0 ] || bad=1
[ "$kp_outer_signal" = 0 ] || exit "$kp_outer_signal"
trap - INT TERM
eval "$kp_outer_int"; eval "$kp_outer_term"
# The marker is beyond terminal-width command output. Use a real isolated
# process group; cleanup only ever targets this test's own child PID/group.
python3 - "$H" <<'PYTEST'
import pathlib, subprocess, sys, uuid
root = pathlib.Path(sys.argv[1])
marker = "safe-killpg-long-" + uuid.uuid4().hex
child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)", "x" * 8192, marker], start_new_session=True)
def signal(required):
    return subprocess.run(["bash", "-c", 'source "$1/tools/safe_killpg.sh"; safe_killpg TERM "$2" "$3"', "test", str(root), str(child.pid), required], capture_output=True, text=True)
try:
    # 等子进程 exec 完再读命令行：Popen 返回时子进程可能还没 exec，ps 读到的是父 python 的命令行、找不到 marker（11-06 本机 10 次红 1 次的候选竞态）
    import time
    deadline = time.monotonic() + 30
    while True:
        command = subprocess.run(["ps", "-ww", "-o", "command=", "-p", str(child.pid)], capture_output=True, text=True).stdout
        if marker in command or time.monotonic() >= deadline: break
        time.sleep(0.05)
    assert marker in command and command.index(marker) > 8192, ("长命令行 30 秒内没在 ps 里出现 marker", command[-200:])
    rejected = signal(marker + "-mismatch")
    assert rejected.returncode == 2 and child.poll() is None, rejected.stderr
    print("Long command mismatch: rejected and child remains alive")
    accepted = signal(marker)
    assert accepted.returncode == 0, accepted.stderr
    child.wait(timeout=5)
    assert child.returncode != 0
    print("Long command match: isolated child group terminated")
finally:
    if child.poll() is None:
        child.terminate()
        child.wait(timeout=5)
PYTEST
rc=$?; [ "$rc" = 0 ] || bad=1
[ $bad = 0 ] && echo "killpg_lint 单测全过" || { echo "killpg_lint 单测有不通"; exit 1; }
