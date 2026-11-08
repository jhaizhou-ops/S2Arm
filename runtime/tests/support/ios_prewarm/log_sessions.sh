#!/bin/bash
# 不改变调用者 HOME；os.c 测试构建只把 HOME 查询映射到子进程的测试容器参数。
set -eu
bin=$1; task_logs=$(mktemp -d); trap 'rm -rf "$task_logs"' EXIT
seed() {
  mkdir -p "$1/Documents"; rm -rf "$1/Documents/logs"
  if [ "$2" = crash ]; then printf 'original session\n【红】CRASH\n' > "$1/Documents/host.log"
  else printf 'original session\n优雅退出完成\n' > "$1/Documents/host.log"; fi
  printf 'older session\n' > "$1/Documents/host.prev.log"
  printf 'oldest session\n' > "$1/Documents/host.prev2.log"
  # 归档按创建时间排序，夹具要显式表达会话先后，不能依赖文件创建落在同一秒。
  SetFile -d '01/01/2026 00:00:01' "$1/Documents/host.prev2.log"
  SetFile -d '01/01/2026 00:00:02' "$1/Documents/host.prev.log"
  SetFile -d '01/01/2026 00:00:03' "$1/Documents/host.log"
}
# 回归：预先放入跨秒且创建时间与会话新旧相反的文件；seed 必须构造真实会话顺序，
# 随后直接执行生产日志轮换与原有断言，不能依赖三个文件恰好创建在同一秒。
container=$task_logs/crossed-seed; mkdir -p "$container/Documents"
: > "$container/Documents/host.log"; : > "$container/Documents/host.prev.log"; : > "$container/Documents/host.prev2.log"
SetFile -d '01/01/2026 00:00:00' "$container/Documents/host.log"
SetFile -d '01/01/2026 00:00:01' "$container/Documents/host.prev.log" "$container/Documents/host.prev2.log"
seed "$container" crash
env -u ActivePrewarm S2A_TEST_APP_HOME="$container" S2A_TEST_SESSION=crash S2A_LOG_CONSOLE=1 "$bin" normal
echo 'PASS 夹具跨秒：按会话新旧归档'
for state in clean crash; do
  container=$task_logs/$state; seed "$container" "$state"
  # 两个未激活预热进程退出，都不能挤掉任何一份原始会话日志。
  before=$(shasum "$container/Documents/host.log" "$container/Documents/host.prev.log" "$container/Documents/host.prev2.log")
  for pass in 1 2; do S2A_TEST_APP_HOME=$container S2A_TEST_SESSION=$state S2A_LOG_CONSOLE=1 ActivePrewarm=1 "$bin" discard; done
  after=$(shasum "$container/Documents/host.log" "$container/Documents/host.prev.log" "$container/Documents/host.prev2.log")
  [ "$before" = "$after" ] || { echo 'FAIL 预热轮换了正式日志'; exit 1; }
  env -u ActivePrewarm S2A_TEST_APP_HOME="$container" S2A_TEST_SESSION=$state S2A_LOG_CONSOLE=1 "$bin" normal
  echo "PASS ${state}：未激活预热两次再普通启动，原会话保留且能按原收尾判断诊断"
  seed "$container" "$state"
  S2A_TEST_APP_HOME=$container S2A_TEST_SESSION=$state S2A_LOG_CONSOLE=1 ActivePrewarm=1 "$bin" activate
  echo "PASS ${state}：激活时才轮换、两个 fd 切到正式日志、重复激活不再轮换"
done
for op in home rename-host open dup-backup dup-stderr; do
  container=$task_logs/fault-normal-$op; seed "$container" clean
  env -u ActivePrewarm S2A_TEST_APP_HOME="$container" S2A_TEST_SESSION=clean S2A_LOG_CONSOLE=1 S2A_TEST_LOG_FAIL="$op" "$bin" fault constructor "$op" 2> "$container/Documents/fallback-stderr.log"
done
for op in home open dup-backup dup-stderr; do
  container=$task_logs/fault-prewarm-$op; seed "$container" clean
  S2A_TEST_APP_HOME=$container S2A_TEST_SESSION=clean S2A_LOG_CONSOLE=1 ActivePrewarm=1 S2A_TEST_LOG_FAIL=$op "$bin" fault constructor "$op" 2> "$container/Documents/fallback-stderr.log"
done
for op in home rename-host open dup-backup dup-stderr dup-native; do
  container=$task_logs/fault-activate-$op; seed "$container" clean
  S2A_TEST_APP_HOME=$container S2A_TEST_SESSION=clean S2A_LOG_CONSOLE=1 ActivePrewarm=1 "$bin" fault activate "$op" 2> "$container/Documents/fallback-stderr.log"
done
# 每局一份：连续普通起 12 次（多数同一秒）→ 归档 9 份 + host.log 共 10 份，文件名两两不同、按名排序 = 起局先后（每局写一行序号，核最新 9 份是第 3–11 局）
container=$task_logs/many; mkdir -p "$container/Documents"
for i in $(seq 1 12); do env -u ActivePrewarm S2A_TEST_APP_HOME="$container" S2A_TEST_SESSION=clean "$bin" start; echo "局 $i" >> "$container/Documents/host.log"; done
n=$(ls "$container/Documents/logs" | grep -c '^host-.*\.log$'); u=$(ls "$container/Documents/logs" | sort -u | wc -l | tr -d ' ')
order=$(for f in $(ls "$container/Documents/logs" | sort); do grep -o '局 [0-9]*' "$container/Documents/logs/$f"; done | tr '\n' ' ')
[ "$n" = 9 ] && [ "$u" = 9 ] && [ -s "$container/Documents/host.log" ] && [ "$order" = "局 3 局 4 局 5 局 6 局 7 局 8 局 9 局 10 局 11 " ] || { echo "FAIL 每局一份：归档 ${n} 份、不同名 ${u}、先后「${order}」"; exit 1; }
echo "PASS 每局一份：连续起 12 次 → 归档 9 份（不同名 ${u}）+ host.log，按名排序即第 3–11 局"
echo '✓ t_ios_prewarm_log'
