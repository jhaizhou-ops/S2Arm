#!/bin/bash
# 门禁覆盖：tools/plock.sh tools/flock_hold.py pack/ipa.sh pack/refresh.sh pack/roots.sh tools/sched.sh tools/gc.sh
# 进程锁单测（tools/plock.sh，审计 P1-27：出包锁 / 刷新锁 / 提交锁 / 登记锁收成一把内核文件锁）：约 10 秒，退出 0 = 全过。期望按规则手写：
#   ① 有人持锁时只试一次 → 返回 1；持有者放锁后等待者拿到
#   ② 持有者被 kill -9 → 2 秒内别人拿到（内核随持锁小进程退出放锁，不靠读 pid 判死）
#   ③ 8 个进程同时抢、临界区里「读计数 → 睡 → 写计数 + 1」并记进出：计数正好 8、进出不交叠（原先 mkdir + 判死删锁的窗口会让两个同时进）
#   ④ 锁路径是旧版 mkdir 锁留下的目录 → 返回 2 并报红，不当「被占」空等
#   ⑤ plock_release 只结束持锁小进程：给一个普通进程的 pid 不杀它
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
source "$H/tools/plock.sh"
L=$T/a.lock
( plock_take "$L" 0 && echo held > "$T/a.state" && sleep 3 ) & A=$!
for i in $(seq 1 100); do [ -s "$T/a.state" ] && break; sleep 0.05; done
plock_take "$L" 0; r1=$?
t0=$SECONDS; plock_take "$L" 10; r2=$?; p2=$PLOCK_PID; dt=$((SECONDS - t0)); plock_release "$p2"; wait $A
ck "① 持锁中只试一次 → 1（实 ${r1}）；放锁后等待者拿到 → 0（实 ${r2}，等了 ${dt} 秒）" '[ $r1 = 1 ] && [ $r2 = 0 ] && [ $dt -le 5 ]'
L=$T/b.lock
( plock_take "$L" 0 && echo held > "$T/b.state" && sleep 60 ) & B=$!
for i in $(seq 1 100); do [ -s "$T/b.state" ] && break; sleep 0.05; done
kill -9 $B; wait $B 2> /dev/null
t0=$SECONDS; plock_take "$L" 30; r3=$?; plock_release "$PLOCK_PID"   # 判返回码不判墙钟：锁没随持有者放 → 等满 30 秒返回 1（mini 负载 200+ 时 python 起一次就过 2 秒，11-02 无缓存实跑 ④ 同形红）
ck "② 持有者 kill -9 → 别人拿到（实 ${r3}，$((SECONDS - t0)) 秒）" '[ $r3 = 0 ]'
L=$T/c.lock; echo 0 > "$T/count"; : > "$T/trace"
for i in $(seq 1 8); do ( PLOCK_POLL_S=0.05 plock_take "$L" 30 || exit 1; echo "in $i" >> "$T/trace"; n=$(cat "$T/count"); sleep 0.1; echo $((n + 1)) > "$T/count"; echo "out $i" >> "$T/trace"; plock_release "$PLOCK_PID" ) & done; wait
ov=$(awk '{if ($1 == "in") { if (open) bad = 1; open = 1 } else open = 0} END {print bad + 0}' "$T/trace")
ck "③ 8 个同时抢：计数 = 8（实 $(cat "$T/count")）、临界区不交叠（交叠 ${ov}）" '[ "$(cat "$T/count")" = 8 ] && [ "$ov" = 0 ]'
mkdir "$T/d.lock"; t0=$SECONDS; plock_take "$T/d.lock" 30 2> "$T/d.err"; r4=$?   # 「不等」由返回码证：当成被占空等只会到上限返回 1，返回 2 只出在起不了持锁进程那一支
ck "④ 锁路径是目录 → 返回 2、报红、不等（实 ${r4}，$((SECONDS - t0)) 秒）" '[ $r4 = 2 ] && grep -q "【红】" "$T/d.err"'
sleep 30 & S=$!; plock_release $S; kill -0 $S 2> /dev/null; r5=$?; kill $S 2> /dev/null
ck "⑤ plock_release 给普通进程 pid → 不杀（还活着：${r5}）" '[ $r5 = 0 ]'
# Linux 登记边界：真正的 pidfd / poll；故障注入只控制退出时点或模拟内核拒绝，不替代成功路径。
python3 - "$PLOCK_PY" "$T" <<'PY'
import os, pathlib, select, subprocess, sys

helper, tmp = sys.argv[1:]
if hasattr(select, "kqueue"):
    print("略 ⑥ Linux pidfd 登记边界（本机走 kqueue，①–⑤照测）")
    sys.exit(0)
# 本组要求 Linux 内核和权限实际支持 pidfd / poll；不满足则报失败，不把未执行的退出竞态算通过。
try:
    capability_fd = os.pidfd_open(os.getpid())
    try:
        capability_poll = select.poll()
        capability_poll.register(capability_fd, select.POLLIN)
        assert not capability_poll.poll(0)
    finally:
        os.close(capability_fd)
except (AttributeError, OSError) as error:
    sys.exit(f"不通 ⑥ 本机不支持 pidfd / poll，登记边界未测：{error}")
runner = pathlib.Path(tmp) / "registration.py"
runner.write_text('''import errno, os, runpy, select, signal, sys
case, helper, lock, holder = sys.argv[1:]
original = getattr(os, "pidfd_open", None)
if case == "race":
    def open_then_exit(pid):
        fd = original(pid)
        os.kill(pid, signal.SIGKILL)
        p = select.poll()
        p.register(fd, select.POLLIN)
        assert p.poll(5000), "合成持锁者未退出"
        return fd
    os.pidfd_open = open_then_exit
elif case == "missing":
    if hasattr(os, "pidfd_open"):
        del os.pidfd_open
elif case in ("denied", "unsupported"):
    def rejected(pid):
        raise OSError(errno.EPERM if case == "denied" else errno.ENOSYS, case)
    os.pidfd_open = rejected
sys.argv = [helper, lock, holder, "take", "plock_hold"]
runpy.run_path(helper, run_name="__main__")
''')
for case in ("dead", "zombie", "race", "missing", "denied", "unsupported"):
    holder = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
    lock = str(pathlib.Path(tmp) / (case + ".lock"))
    try:
        if case in ("dead", "zombie"):
            holder.kill()
            if case == "dead":
                holder.wait()
            else:
                os.waitid(os.P_PID, holder.pid, os.WEXITED | os.WNOWAIT)
        result = subprocess.run([sys.executable, str(runner), case, helper, lock, str(holder.pid)],
                                capture_output=True, text=True, timeout=10)
        assert result.returncode == 2 and not result.stdout.strip(), (case, result)
        # 失败的守护进程退出后应放锁；不改 inode、不残留持锁小进程。
        probe = subprocess.run([sys.executable, helper, lock, str(os.getpid()), "probe"],
                               capture_output=True, timeout=10)
        assert probe.returncode == 0, (case, probe)
        print(f"通 ⑥ {case} → 2、无成功 PID、锁已释放")
    finally:
        if holder.poll() is None:
            holder.kill()
        holder.wait()
PY
r6=$?; ck "⑥ Linux 登记边界全部通过" '[ $r6 = 0 ]'
[ $bad = 0 ] && echo "plock 单测全过" || { echo "plock 单测有不通"; exit 1; }
