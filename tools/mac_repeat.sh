#!/bin/bash
# 同款反复起局（原生层线 10-28 梳理「合 1」：替掉 run 目录里 11 个手写一次性 smg2*.sh）：
#   bash tools/mac_repeat.sh <输出目录> <款> --root <产物根> [--rounds N] [--par P] [--sec S] [--build] [--stop-on-crash] [-- 变量=值 …]
#   每轮并行 P 局（缺省 2），共 N 轮（缺省 5），每局经 tools/mac_health.sh 起（HEALTH_PAR=1、HEALTH_SEC=S，缺省 200）；
#   局目录 <输出目录>/r<轮><a|b|…>/<款>/host.log。-- 之后的「变量=值」原样带进每一局（数组，不经 shell 分词：zsh 下 env $V 不拆的坑）。
#   --root 必须给：这一款的产物根目录本身（= mac_health 的 HEALTH_ROOT_<款>，如 ~/.s2arm/run/s2arm/roots/witcher3@pkg-…），显式产物根不走 pack/refresh.sh（@现行 根先刷新，本机盘不足时出包暂停、局空等，10-28 巫师3 等了 28 分钟）。
#   --build：起局前 S2A_CS=1 make -s host 一次。--stop-on-crash：某轮有崩就不再起下一轮（抓现场用）。
#   每局一行「r1a 首帧=1 崩=0 MARK=帧 4178」，末行「mac_repeat：<款> 局 N，有首帧 F，崩 C，到 MARK M」；有首帧的局里有崩 → 退出 1，否则 0。
#   判据字样与 tools/health_table.py 同口径：「首帧上屏」「CRASH 信号」「S2A 标记 MARK：帧 N」。
#   单测：tests/mac_repeat_test.sh（MAC_REPEAT_HEALTH 指向假 mac_health，核参数透传、汇总与退出码）
set -u
H=$(cd "$(dirname "$0")/.." && pwd)
[ $# -ge 2 ] || { echo "用法：mac_repeat.sh <输出目录> <款> --root <产物根> [--rounds N] [--par P] [--sec S] [--build] [--stop-on-crash] [-- 变量=值 …]" >&2; exit 2; }
O=$1; G=$2; shift 2
ROOT=; N=5; P=2; SEC=200; BUILD=0; STOP=0; EXTRA=()
while [ $# -gt 0 ]; do
  case $1 in
    --root) ROOT=$2; shift 2;;
    --rounds) N=$2; shift 2;;
    --par) P=$2; shift 2;;
    --sec) SEC=$2; shift 2;;
    --build) BUILD=1; shift;;
    --stop-on-crash) STOP=1; shift;;
    --) shift; EXTRA=("$@"); break;;
    *) echo "mac_repeat：不认识的参数 $1" >&2; exit 2;;
  esac
done
[ -n "$ROOT" ] || { echo "mac_repeat：必须给 --root <产物根>（不走 @现行 刷新）" >&2; exit 2; }
[ -d "$ROOT" ] && [ -n "$(ls -A "$ROOT" 2> /dev/null)" ] || { echo "mac_repeat：产物根不存在或是空的：${ROOT}（给这一款的产物根目录本身，如 roots/witcher3@pkg-…）" >&2; exit 2; }
ROOT=$(cd -P "$ROOT" && pwd)
MH=${MAC_REPEAT_HEALTH:-$H/tools/mac_health.sh}
cd "$H" || exit 2
if [ $BUILD = 1 ]; then S2A_CS=1 make -s host > "$O.build.log" 2>&1 || { echo "mac_repeat：🔴 编译失败（$O.build.log）"; exit 2; }; fi
mkdir -p "$O"
tag() { printf "\\x$(printf %x $((97 + $1)))"; }   # 0 → a, 1 → b …
games=0; first=0; crash=0; mark=0
for r in $(seq 1 "$N"); do
  pids=()
  for k in $(seq 0 $((P - 1))); do
    d=$O/r$r$(tag "$k")
    rm -rf "$d"
    ( env "${EXTRA[@]}" GAMES="$G" HEALTH_PAR=1 HEALTH_SEC="$SEC" "HEALTH_ROOT_$G=$ROOT" bash "$MH" "$d" "$G" > "$d.log" 2>&1 ) &
    pids+=($!)
  done
  wait "${pids[@]}"
  rc_round=0
  for k in $(seq 0 $((P - 1))); do
    t=r$r$(tag "$k"); L=$O/$t/$G/host.log
    f=$(grep -ac '首帧上屏' "$L" 2> /dev/null); c=$(grep -ac 'CRASH 信号' "$L" 2> /dev/null)
    m=$(grep -aoE 'S2A 标记 MARK：帧 [0-9]+' "$L" 2> /dev/null | head -1 | grep -oE '[0-9]+$')
    games=$((games + 1)); [ "${f:-0}" -gt 0 ] && first=$((first + 1)); [ -n "$m" ] && mark=$((mark + 1))
    [ "${f:-0}" -gt 0 ] && [ "${c:-0}" -gt 0 ] && { crash=$((crash + 1)); rc_round=1; }
    echo "$t 首帧=${f:-0} 崩=${c:-0} MARK=$([ -n "$m" ] && echo "帧 $m" || echo 没到)"
  done
  [ $STOP = 1 ] && [ $rc_round = 1 ] && { echo "mac_repeat：第 ${r} 轮有崩，按 --stop-on-crash 停"; break; }
done
echo "mac_repeat：${G} 局 ${games}，有首帧 ${first}，崩 ${crash}，到 MARK ${mark}"
[ $crash = 0 ]
