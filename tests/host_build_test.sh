#!/bin/bash
# 门禁覆盖：tools/host_build.sh runtime/run_mac.sh pack/stage_extract.sh tools/census/census.sh tools/frame_replay.sh tools/mac_health.sh
# tools/host_build.sh 单测（11-04 合入运维线）：同一棵树两个入口并发编宿主，不再互相覆盖。期望全部按规则手写：
#   替身 make 模拟 Makefile 的构建配置戳：.host_cfg 里的 S2A_CS 和这次不同就重链 build/s2arm-host（写「cs=<值>」，链接期间 1 秒，
#   期间另一次 make 进来记一行「并发」）；相同就是空操作。
#   ① 对照（旧做法，原样照 main 29d9e74f8 的两条命令）：起局入口加锁 S2A_CS=1、出包入口不加锁 S2A_CS=0 → 出现并发或宿主被盖成 cs=0（证明问题真存在）
#   ② 新做法：两个入口都走 host_build.sh（一个 S2A_CS=1、一个 S2A_CS=0）→ 没有并发、宿主 cs=1、配置戳 S2A_CS=1
#   ③ 只升不降：树里已是 S2A_CS=1，单独调 S2A_CS=0 → 不重链（宿主仍 cs=1）
#   ④ 不给 S2A_CS → 按 1 编
#   ⑤ 持锁进程被 kill -9 → 锁随之释放，下一个调用拿到锁并编完（按事件判：持锁方链接要占 10 万秒，锁没放下一个调用只会等到 S2A_HOST_LOCK_S 超时退出 75；不判墙钟）
#   ⑥ 接线：6 个编宿主的入口都调 host_build.sh，仓库脚本里没有别处裸 make host
set -u
H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
chk() { if [ "$2" = "$3" ]; then echo "🟢 $1"; else echo "🔴 $1：期望「$2」→ 真结果「$3」"; bad=1; fi; }
mkdir -p "$T/bin" "$T/tree/tools"; cp "$H/tools/host_build.sh" "$T/tree/tools/"
cat > "$T/bin/make" <<'EOF'
#!/bin/bash
# 替身 make：只认 -C <树>，按 S2A_CS 模拟配置戳与重链
while [ $# -gt 0 ]; do [ "$1" = -C ] && { d=$2; shift; }; shift; done
b=$d/build; mkdir -p "$b"; cfg="S2A_CS=${S2A_CS:-} CC=cc"
[ "$(cat "$b/.host_cfg" 2> /dev/null)" = "$cfg" ] && [ -f "$b/s2arm-host" ] && exit 0
[ -e "$b/.linking" ] && echo 并发 >> "$b/overlap"
touch "$b/.linking"; printf '%s' "$cfg" > "$b/.host_cfg"; rm -f "$b/s2arm-host"; sleep "${FAKE_LINK_S:-1}"
echo "cs=${S2A_CS:-}" > "$b/s2arm-host"; rm -f "$b/.linking"; echo "cs=${S2A_CS:-}" >> "$b/links"
EOF
chmod +x "$T/bin/make"; export PATH=$T/bin:$PATH
B=$T/tree/build; reset_() { rm -rf "$B"; mkdir -p "$B"; }
wait_link() { local i; for i in $(seq 1 200); do [ -e "$B/.linking" ] && return 0; sleep 0.1; done; return 1; }   # 等先到的那个真进了重链再起后到的（定序，不靠 sleep 碰运气）
# ①
reset_
( mkdir -p "$T/tree/build"; S2A_CS=1 lockf -k "$T/tree/build/.make_host.lock" make -C "$T/tree" -s host ) & a=$!
wait_link; ( S2A_CS=0 make -C "$T/tree" ROOT="$T/tree" -s host ) & b=$!; wait $a $b
o1=$( { [ -e "$B/overlap" ] || [ "$(cat "$B/s2arm-host" 2> /dev/null)" != cs=1 ]; } && echo 复现 || echo 没复现)
chk "① 对照：旧做法两入口并发 → 出现并发重链或宿主被盖（$(cat "$B/s2arm-host" 2> /dev/null)，并发 $(cat "$B/overlap" 2> /dev/null | wc -l | tr -d " ")）" 复现 "$o1"
# ②
reset_
( S2A_CS=1 bash "$T/tree/tools/host_build.sh" ) & a=$!
wait_link; ( S2A_CS=0 bash "$T/tree/tools/host_build.sh" --tree "$T/tree" ROOT="$T/tree" ) & b=$!; wait $a $b
chk "② 新做法两入口并发 → 无并发、宿主 cs=1、配置戳 S2A_CS=1" "无 cs=1 S2A_CS=1 CC=cc" "$([ -e "$B/overlap" ] && echo 有 || echo 无) $(cat "$B/s2arm-host") $(cat "$B/.host_cfg")"
# ③
: > "$B/links"; S2A_CS=0 bash "$T/tree/tools/host_build.sh"
chk "③ 树里已是 S2A_CS=1，再给 0 → 不重链、宿主仍 cs=1" "0 cs=1" "$(wc -l < "$B/links" | tr -d ' ') $(cat "$B/s2arm-host")"
# ④
reset_; ( unset S2A_CS; bash "$T/tree/tools/host_build.sh" )
chk "④ 不给 S2A_CS → 按 1 编" cs=1 "$(cat "$B/s2arm-host")"
# ⑤
reset_; ( FAKE_LINK_S=100000 S2A_CS=1 bash "$T/tree/tools/host_build.sh" ) & k=$!; sleep 0.5
pkill -9 -P $k 2> /dev/null; pkill -9 -f "$T/bin/make" 2> /dev/null; kill -9 $k 2> /dev/null; wait $k 2> /dev/null; rm -f "$B/.linking"
S2A_HOST_LOCK_S=120 S2A_CS=1 bash "$T/tree/tools/host_build.sh"; rc=$?; pkill -9 -f "sleep 100000" 2> /dev/null
chk "⑤ 持锁进程被 kill -9 → 锁释放，下一个调用拿到锁并编完（持锁方本要占 10 万秒；锁没放 = 等满 120 秒退出 75）" "0 cs=1" "$rc $(cat "$B/s2arm-host" 2> /dev/null)"
# ⑥
w=0; for f in runtime/run_mac.sh pack/stage_extract.sh tools/frame_replay.sh; do grep -q 'tools/host_build.sh' "$H/$f" && w=$((w + 1)); done
bare=$(cd "$H" && git grep -nE '\bmake\b[^#]*\bhost\b' -- '*.sh' | grep -vE '^tests/|^tools/host_build.sh' | wc -l | tr -d ' ')
chk "⑥ 接线：3 个入口都调 host_build.sh、仓库脚本里裸 make host 0 处" "3 0" "$w $bare"
[ $bad = 0 ] && echo "宿主编译锁单测全绿" || { echo "宿主编译锁单测有红"; exit 1; }
