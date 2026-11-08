#!/bin/bash
# 带上限跑一条命令，超时前抓现场再杀（10-23 总指挥：渲染器单测今天 4 次 300 秒超时、一行没出，不循环复现，等下一次自然发生时带栈）。
#   用法：timeout_snap.sh <上限秒> <现场文件> <命令> [参数…]
#   命令在独立进程组里跑；到「上限 − 10 秒」还没结束：对进程组里每个进程 + 本用户的 MTLCompilerService（系统编译服务不是我们的子进程，卡在编译时栈在它那里）
#   并行 sample 5 秒，连同进程树（ps）、vm_stat、负载写进现场文件；到上限杀整个进程组（先 TERM、2 秒后 KILL），退出 124（同 timeout）。
#   没超时：原样返回命令的退出码，不写现场文件。S2A_SNAP_PEER=<ssh 目标> 时另记对端负载（3 秒连不上就记连不上）。
#   按进度判（S2A_SNAP_STALL=<秒>:<目录>，10-23 离线编 metallib）：目录下（含子目录）持续有新建 / 改名进来的文件（所在目录 mtime 新于上次查看）就不判超时，
#   连续 <秒> 没有新文件才按超时处理（抓现场 → 杀组 → 124）；<上限秒> 仍是总上限。
#   编译进程还在算也不算停滞（10-26 交付线：Air 8 核负载 15、直连库同时在跑，斯普拉遁3 通用段单个大着色器 metal 编了约 10 分钟、CPU 63%，
#   目录 590 秒没新文件被判挂死，整包出不来）：这 10 秒里命令进程树中有进程的累计 CPU 时间涨了 ≥ 1 秒，就当有进度；真挂死的编译器 CPU 不涨，照样抓得到。
#   逐进程比（同一进程号前后两次），不比总和：子进程退出后它的 CPU 时间就不在树里了，总和会掉。现场另记累计「在算」秒数
#   现场按命令的进程树采（含自立进程组的子孙：嵌套的 timeout_snap / perl setpgrp 起的命令不在本组里，原先采不到）
set -u
source "$(cd "$(dirname "$0")/../../tools" && pwd)/safe_killpg.sh" || exit 2
LIM=${1:?上限秒}; SNAP=${2:?现场文件}; shift 2; [ $# -gt 0 ] || { echo "用法：timeout_snap.sh <上限秒> <现场文件> <命令…>" >&2; exit 2; }
STALL=0; SDIR=
if [ -n "${S2A_SNAP_STALL:-}" ]; then STALL=${S2A_SNAP_STALL%%:*}; SDIR=${S2A_SNAP_STALL#*:}
  case $STALL in ''|*[!0-9]*) echo "timeout_snap：S2A_SNAP_STALL 要 <秒>:<目录>" >&2; exit 2;; esac; [ "$STALL" -gt 20 ] || { echo "timeout_snap：停滞秒数要 > 20" >&2; exit 2; }; fi
STAMP=$(mktemp); trap 'rm -f "$STAMP" "${CPUF:-}"' EXIT
tree() {   # 命令进程 P 及其全部子孙（不论进程组）
  ps -A -o pid=,ppid= 2> /dev/null | awk -v r="$P" '{ c[$2] = c[$2] " " $1 } END { q[1] = r; n = 1; for (i = 1; i <= n; i++) { print q[i]; k = split(c[q[i]], a, " "); for (j = 1; j <= k; j++) q[++n] = a[j] } }'; }
QC=0; CPUF=$(mktemp)
# 进程树里每个进程的累计 CPU 时间（厘秒）：「进程号 厘秒」，ps 的 time 格式 [[天-]时:]分:秒.百分秒
cpu_now() { local t; t=$(tree | tr '\n' ','); [ -n "$t" ] && ps -o pid=,time= -p "${t%,}" 2> /dev/null | awk '{ n = split($2, a, /[-:]/); s = 0; for (i = n; i >= 1; i--) { v = a[i] + 0; if (i == n) s += v * 100; else if (n - i == 1) s += v * 6000; else if (n - i == 2) s += v * 360000; else s += v * 8640000 } printf "%s %d\n", $1, s }'; }
# 上次查看以来有进程的 CPU 时间涨了 ≥ 100 厘秒（1 秒）：退出 0；首次查看只记基线
cpu_moving() { local now; now=$(cpu_now); local r; r=$(printf '%s\n' "$now" | awk -v f="$CPUF" 'BEGIN { while ((getline l < f) > 0) { split(l, a, " "); o[a[1]] = a[2] } } NF == 2 && ($1 in o) && $2 - o[$1] >= 100 { m = 1 } END { print m + 0 }'); printf '%s\n' "$now" > "$CPUF"; [ "$r" = 1 ]; }
lim_now() {   # 当前有效上限（相对起跑的秒数）：按进度判时 = 最后一次见到新产出 + 停滞秒数，且不超总上限
  if [ "$STALL" -gt 0 ]; then local l=$((last - t0 + STALL)); [ $l -lt "$LIM" ] && echo $l || echo "$LIM"; else echo "$LIM"; fi; }
pre_of() { local l=$1; echo $(( l > 20 ? l - 10 : l / 2 )); }
perl -e 'setpgrp(0, 0); exec @ARGV or exit 127' -- "$@" &
P=$!
# 本脚本被 TERM / INT（外层同类看门狗杀它所在的组）时把命令的进程组一并收掉：命令在自己的组里，不转发就成孤儿（嵌套时外层杀不到内层）
fwd() { safe_killpg TERM "$P" 2> /dev/null; sleep 1; for q in $(pgrep -g "$P" 2> /dev/null); do kill -KILL "$q" 2> /dev/null; done; exit 143; }
trap fwd TERM INT
t0=$SECONDS; last=$SECONDS; nxt=$((SECONDS + 10)); based=0
while kill -0 "$P" 2> /dev/null && [ $((SECONDS - t0)) -lt "$(pre_of "$(lim_now)")" ]; do
  sleep 1
  [ "$STALL" -gt 0 ] && [ $based = 0 ] && based=1 && cpu_now > "$CPUF"   # CPU 基线：起跑 1 秒后记一次，第一次 10 秒查看就能比（停滞上限 21 秒时第 11 秒就要定是否抓现场）
  # 每 10 秒看一次有没有新产出：只看目录的修改时间（新建 / 改名进来的文件会刷新它所在目录），不逐个 stat 文件
  #   （10-26 交付线：斯普拉遁3 着色器目录 10 万级文件，-type f 每轮全扫一遍，单个 find 吃 72% CPU；同样 10 万个文件，按目录查约便宜 25 倍）
  #   按墙钟查，不按轮数：满负载下每轮远不止 1 秒，数到第 10 轮时可能已过抓现场点（10-31 mini 无缓存全套：持续写文件的例 25 秒被误杀）；
  #   到了抓现场点也先查一次再定，不拿 10 秒前的读数判停滞
  if [ "$STALL" -gt 0 ] && { [ $SECONDS -ge $nxt ] || [ $((SECONDS - t0)) -ge "$(pre_of "$(lim_now)")" ]; }; then nxt=$((SECONDS + 10))
    mv=0; cpu_moving && mv=1   # 每次都读（基线每 10 秒刷新，不会拿很久以前的读数比出假进度）
    if [ -n "$(find "$SDIR" -type d -newer "$STAMP" -print -quit 2> /dev/null)" ]; then touch "$STAMP"; last=$SECONDS
    elif [ $mv = 1 ]; then last=$SECONDS; QC=$((QC + 10)); fi   # 编译器还在算（CPU 时间在涨）：大着色器争核时编得慢，不是卡死
  fi
done
LIM=$(lim_now)   # 定格：此后抓现场、杀组都按这一刻的有效上限
if ! kill -0 "$P" 2> /dev/null; then wait "$P"; exit $?; fi
# ---- 抓现场 ----
mkdir -p "$(dirname "$SNAP")"
rm -f "$SNAP.digest"
{
  echo "### 超时前现场：$(date '+%F %T')，命令已跑 $((SECONDS - t0)) 秒（上限 $LIM 秒$([ "$STALL" -gt 0 ] && echo "；按进度判：$SDIR 已 $((SECONDS - last)) 秒没有新文件，停滞上限 $STALL 秒；最近的文件 $(find "$SDIR" -type f -print0 2> /dev/null | xargs -0 stat -f '%m %N' 2> /dev/null | sort -rn | head -1 | cut -d' ' -f2- | xargs basename 2> /dev/null)")）：$*"
  echo "### 负载：$(sysctl -n vm.loadavg)，核数 $(sysctl -n hw.ncpu)，主机 $(hostname -s)"
  if [ -n "${S2A_SNAP_PEER:-}" ]; then echo "### 对端 ${S2A_SNAP_PEER} 负载：$(ssh -o BatchMode=yes -o ConnectTimeout=3 "$S2A_SNAP_PEER" 'sysctl -n vm.loadavg' 2>&1 | head -1)"; fi
  [ "$QC" -gt 0 ] && echo "### 编译进程在算（CPU 时间在涨）：累计约 $QC 秒（不计停滞）"
  echo "### 进程组 ${P}（进程树）："
  TR=$(tree | tr '\n' ','); [ -n "$TR" ] && ps -o pid,ppid,pgid,stat,%cpu,rss,etime,command -p "${TR%,}" 2> /dev/null | cut -c1-300
  echo "### 本机 CPU 前 15："
  ps -A -o pid,%cpu,rss,etime,comm -r | head -16
  echo "### vm_stat："
  vm_stat
} > "$SNAP" 2>&1
# 抓现场必须在上限前收完（10-23 mini 上 MTLCompilerService 多、每个 sample 5 秒 + 等 9 秒，12 秒上限的单测 21 秒才杀）：
#   至多 8 个进程（先进程组、再本用户编译服务），每个 sample 3 秒，等到「上限 − 2 秒」为止，没采完的采样进程按自己记下的 pid 收掉
pids=$( { tree; pgrep -x -u "$(id -u)" MTLCompilerService 2> /dev/null; } | head -8)
D=$(mktemp -d); spids=()
for p in $pids; do sample "$p" 3 -mayDie -file "$D/$p.txt" > /dev/null 2>&1 & spids+=($!); done
alive() { local q; for q in ${spids[@]+"${spids[@]}"}; do kill -0 "$q" 2> /dev/null && return 0; done; return 1; }
while alive && [ $((SECONDS - t0)) -lt $((LIM - 2)) ]; do sleep 1; done
for q in ${spids[@]+"${spids[@]}"}; do kill "$q" 2> /dev/null; done
for p in $pids; do
  # 没采到也要留一行原因（10-23 总指挥：mini 高负载下 sample 3 秒内起不来，判据不能依赖它）：上限前没收完 / sample 自己退出没写 / 进程已退出
  if [ ! -s "$D/$p.txt" ]; then echo "### sample ${p}（$(ps -o comm= -p "$p" 2> /dev/null || echo 已退出)）：没采到——$(kill -0 "$p" 2> /dev/null && echo "上限 − 2 秒前 sample 没写出（负载 $(sysctl -n vm.loadavg)）" || echo "进程已退出")"; echo "sample $p 没采到" >> "$SNAP.digest"; continue; fi
  echo "### sample ${p}（$(ps -o comm= -p "$p" 2> /dev/null || echo 已退出)）："
  # 只留调用栈段（Call graph 到 Binary Images 之前），去掉文件头与镜像表
  awk '/^Call graph:/ { on = 1 } /^Binary Images:/ { on = 0 } on' "$D/$p.txt" | head -400
  # 摘要一行（进 $SNAP.digest，门禁红行里带出）：第一个线程最重那条路径（sample 子节点按次数降序，第一条链即最重）末 6 帧 + 栈顶最多的符号
  python3 - "$D/$p.txt" "$p" "$(ps -o comm= -p "$p" 2> /dev/null | xargs basename 2> /dev/null || echo 已退出)" >> "$SNAP.digest" <<'PY'
import re, sys
L = open(sys.argv[1], errors='replace').read().split('\n')
try: i = L.index('Call graph:')
except ValueError: sys.exit(0)
chain, last = [], -1
for l in L[i + 2:]:
    m = re.match(r'^([ +!:|]*)(\d+) (.+)$', l)
    if not m: break
    d = len(m.group(1))
    if d <= last: break
    last = d; chain.append(re.sub(r'\s+\(in ([^)]+)\).*', r'(\1)', m.group(3)).strip())
top = next((L[j + 1].strip() for j, l in enumerate(L) if l.startswith('Sort by top of stack')), '')
print(f"{sys.argv[3]}[{sys.argv[2]}] 最重路径末段：{' ← '.join(reversed(chain[-6:]))}；栈顶最多：{re.sub(r'  +', ' ', top)}"[:400])
PY
done >> "$SNAP"
rm -rf "$D"
# ---- 到上限杀整组 ----
while kill -0 "$P" 2> /dev/null && [ $((SECONDS - t0)) -lt "$LIM" ]; do sleep 1; done
if kill -0 "$P" 2> /dev/null; then
  # 进程组信号只经 tools/safe_killpg.sh（组长须是本进程后代）；TERM 后组长若已退出、组里还有残余，逐个 KILL（不按组号发）
  safe_killpg TERM "$P" 2> /dev/null; sleep 2
  for q in $(pgrep -g "$P" 2> /dev/null); do kill -KILL "$q" 2> /dev/null; done
  wait "$P" 2> /dev/null
  echo "### 到上限 $LIM 秒，已杀进程组 $P" >> "$SNAP"
  exit 124
fi
wait "$P"; exit $?
