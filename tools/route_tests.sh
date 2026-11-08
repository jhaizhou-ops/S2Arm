#!/bin/bash
# 本地受影响单测：bash tools/route_tests.sh [--base origin/main] [--dry-run]
#   [--keep-going] [--timeout 600]；超时为正整数秒，不依赖 GNU timeout。
# 改动 = base...HEAD + 暂存/未暂存/未跟踪；临时 index 让新单测参与原路由器，
# 不改真实 index。空改动不回退全跑；dry-run 只输出清单，不执行测试。
# 退出 0 全绿 / 1 有红或少跑 / 2 参数、环境或清理失败；INT/TERM/HUP 为 130/143/129。
set -u
usage() { sed -n '2,7p' "$0"; }
error() { echo "route_tests：$*" >&2; exit 2; }
BASE=origin/main; DRY=0; KEEP=0; LIMIT=600
while [ $# -gt 0 ]; do
  case $1 in
    --base|--timeout)
      opt=$1; value=${2:-}
      case $value in ''|-*) error "$opt 缺少有效参数";; esac
      if [ "$opt" = --base ]; then BASE=$value; else LIMIT=$value; fi
      shift 2;;
    --dry-run) DRY=1; shift;;
    --keep-going) KEEP=1; shift;;
    -h|--help) usage; exit 0;;
    *) error "未知参数 $1";;
  esac
done
# 限制位数避免 bash 算术溢出；拒绝 0、小数及八进制歧义。
[[ $LIMIT =~ ^[1-9][0-9]{0,8}$ ]] || error '--timeout 必须为正整数秒（最多 9 位）'
[ "${BASH_VERSINFO[0]}" -ge 5 ] || error '需要 bash 5+'
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || error '请在 git 仓库内运行'
cd "$ROOT" || error '无法进入仓库根'
for cmd in python3 git mktemp mkfifo ps; do command -v "$cmd" >/dev/null || error "缺工具 $cmd"; done
[ -f tools/gate_route.py ] && [ -f tools/safe_killpg.sh ] || error '缺路由器或 safe_killpg.sh'
source tools/safe_killpg.sh || error '无法加载 safe_killpg.sh'
TMP=$(mktemp -d "${TMPDIR:-/tmp}/s2a-route-tests.XXXXXXXX") || error '无法创建临时目录'
ACTIVE=; INTERRUPTED=0; PRESERVE=0
# 持有 FIFO 的两端，只用 bash read -t 等待；没有 sleep/timeout 的额外进程。
mkfifo "$TMP/tick" || { rmdir "$TMP"; error '无法创建计时 FIFO'; }
exec 9<>"$TMP/tick" || error '无法打开计时 FIFO'
tick() { read -r -t 0.05 -u 9 _ || :; }
active_job() {
  local p
  for p in $(jobs -pr; jobs -ps); do [ "$p" = "$ACTIVE" ] && return 0; done
  return 1
}
stop_group() {
  local deadline
  [ -n "$ACTIVE" ] || return 0
  # 组长在写完结果后保持存活，避免父进程先退出导致 helper 无从核身份。
  safe_killpg KILL "$ACTIVE" || { PRESERVE=1; return 1; }
  deadline=$((SECONDS + 5))
  # jobs 在回收已终止作业时会打印整段后台函数；只静音该作业表通知。
  while active_job 2>/dev/null; do
    [ "$SECONDS" -lt "$deadline" ] || { PRESERVE=1; return 1; }
    tick
  done
  wait "$ACTIVE" 2>/dev/null || :
  ACTIVE=
}
cleanup() {
  local rc=$?
  trap '' INT TERM HUP
  # 退出前统一复核，覆盖末项日志/汇总阶段才收到的信号；清理失败仍优先报 2。
  if [ "$INTERRUPTED" != 0 ]; then
    rc=$INTERRUPTED
    echo "route_tests：收到信号，结果不完整（rc=${rc}）" >&2
  fi
  stop_group || { echo "route_tests：回收失败，保留现场 $TMP" >&2; rc=2; }
  exec 9>&-
  if [ "$PRESERVE" = 0 ]; then rm -rf "$TMP"; fi
  exit "$rc"
}
trap cleanup EXIT
# spawn 到 $! 登记期间只记中断，确保 EXIT 清理仍拥有已登记的子进程。
trap 'INTERRUPTED=130' INT
trap 'INTERRUPTED=143' TERM
trap 'INTERRUPTED=129' HUP

# 保留 git 的 NUL 路径边界；路由使用独立 index 看工作树的新文件/删除，
# 真实 index 字节不变，也不写提交/分支；-N 不把未跟踪文件内容写入对象库。
if ! python3 - "$BASE" "$TMP" <<'PY'
import os
from pathlib import Path
import shutil
import subprocess
import sys

base, temp = sys.argv[1], Path(sys.argv[2])
def git(*args, env=None):
    return subprocess.check_output(['git', *args], env=env)
try:
    commit = git('rev-parse', '--verify', '--end-of-options', base + '^{commit}').decode().strip()
    changed = set(git('diff', '--no-renames', '--name-only', '-z', commit + '...HEAD').split(b'\0'))
    # Do not diff HEAD directly: staged and unstaged edits can cancel to HEAD.
    changed.update(git('diff', '--cached', '--no-renames', '--name-only', '-z', 'HEAD').split(b'\0'))
    changed.update(git('diff', '--no-renames', '--name-only', '-z').split(b'\0'))
    changed.update(git('ls-files', '--others', '--exclude-standard', '-z').split(b'\0'))
    changed.discard(b'')
    (temp / 'changed').write_bytes(b''.join(p + b'\0' for p in sorted(changed)))
    if changed:
        index = Path(os.fsdecode(git('rev-parse', '--git-path', 'index').rstrip(b'\n')))
        env = os.environ.copy()
        env['GIT_INDEX_FILE'] = str(temp / 'index')
        shutil.copyfile(index, env['GIT_INDEX_FILE'])
        git('add', '-N', '-A', '--', '.', env=env)
        result = subprocess.run([sys.executable, 'tools/gate_route.py', 'tests',
                                 *[os.fsdecode(p) for p in sorted(changed)]],
                                env=env, stdout=subprocess.PIPE, check=True)
        (temp / 'tests').write_bytes(result.stdout)
except (OSError, subprocess.CalledProcessError) as exc:
    print(f'route_tests：改动集或路由失败：{exc}', file=sys.stderr)
    sys.exit(2)
PY
then exit 2; fi
[ "$INTERRUPTED" = 0 ] || exit "$INTERRUPTED"
if [ ! -s "$TMP/changed" ]; then echo '改动集为空，未跑任何单测'; exit 0; fi
TESTS=()
while IFS= read -r test || [ -n "$test" ]; do
  [ -n "$test" ] || continue
  [[ $test =~ ^tests/[^/]+_test\.sh$ && $test != *$'\t'* ]] || error "路由返回非法单测路径：$test"
  [ -f "$test" ] || error "路由单测不存在：$test"
  found=0
  for prior in "${TESTS[@]}"; do [ "$prior" = "$test" ] && found=1; done
  [ "$found" = 1 ] || TESTS+=("$test")
done < "$TMP/tests"
if [ "$DRY" = 1 ]; then
  for test in "${TESTS[@]}"; do printf '%s\n' "$test"; done
  exit 0
fi
N=${#TESTS[@]}; RAN=0; GREEN=0; RED=0; RESULT=0
ROWS=()
for test in "${TESTS[@]}"; do
  [ "$INTERRUPTED" = 0 ] || exit "$INTERRUPTED"
  RAN=$((RAN + 1)); OUT=$TMP/$RAN; mkdir "$OUT" || error '无法创建单测日志目录'
  start=$SECONDS; timed=0
  # monitor 模式只用于创建独立的子作业进程组；组内禁用 monitor，孙进程同组。
  # 监督 shell 不因 TERM 提前退出；等待测试回收其子进程后写结果，再等父进程收组。
  set -m
  (
    trap - EXIT INT HUP
    trap ':' TERM
    set +m
    bash "$test" 9>&- & child=$!
    while :; do
      wait "$child"; rc=$?
      running=0
      for p in $(jobs -pr; jobs -ps); do [ "$p" = "$child" ] && running=1; done
      [ "$running" = 1 ] || break
    done
    printf '%s\n' "$rc" > "$OUT/rc.tmp" && mv "$OUT/rc.tmp" "$OUT/rc"
    while :; do tick; done
  ) > "$OUT/log" 2>&1 & ACTIVE=$!
  set +m
  while [ ! -f "$OUT/rc" ]; do
    [ "$INTERRUPTED" = 0 ] || exit "$INTERRUPTED"
    active_job || error "单测监督进程意外退出：${test}（日志 $OUT/log）"
    if [ $((SECONDS - start)) -ge "$LIMIT" ]; then
      timed=1
      safe_killpg TERM "$ACTIVE" || error "超时进程组回收被拒：$test"
      deadline=$((SECONDS + 2))
      while [ ! -f "$OUT/rc" ] && [ "$SECONDS" -lt "$deadline" ]; do tick; done
      break
    fi
    tick
  done
  if [ "$timed" = 1 ]; then rc=124; else read -r rc < "$OUT/rc" || error "读取退出码失败：$test"; fi
  [[ $rc =~ ^[0-9]+$ ]] || error "非法退出码：$test"
  stop_group || error "进程组未完整回收：$test"
  elapsed=$((SECONDS - start))
  cat "$OUT/log"
  [ "$INTERRUPTED" = 0 ] || exit "$INTERRUPTED"
  if [ "$rc" = 0 ]; then GREEN=$((GREEN + 1)); label='绿 (rc=0)'
  else RED=$((RED + 1)); RESULT=1; label="红 (rc=$rc)"; [ "$timed" = 0 ] || label="红 (超时，rc=124)"; fi
  ROWS+=("$test"$'\t'"$elapsed"$'\t'"$label")
  if [ "$rc" != 0 ] && [ "$KEEP" = 0 ]; then break; fi
done
[ "$INTERRUPTED" = 0 ] || exit "$INTERRUPTED"
printf '\n单测\t秒\t结果\n'
for row in "${ROWS[@]}"; do printf '%s\n' "$row"; done
[ "$RAN" = "$N" ] || RESULT=1
printf '跑了 %s 个 / 应跑 %s 个，绿 %s 红 %s\n' "$RAN" "$N" "$GREEN" "$RED"
exit "$RESULT"
