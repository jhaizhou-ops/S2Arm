#!/bin/bash
# 远端资源包缓存回收（调度往 mini 推 packs/<款> 之前调）：bash packs_evict.sh <packs 目录> <这次要推的款> <这份包 GB>
#   按最久未用逐款删别的款，直到「可用 − 这份包 ≥ S2A_PACKS_FLOOR_GB（缺省 40）」；这次的款、正被作业引用的款（jobs/*/pack 指向）不删。
#   最近一次使用记在 packs/.used_<款>（推完 touch；rsync -a 会把目录时间改回源的时间，不能拿目录时间当使用时间）。
#   10-28 17:3x mini 盘满：每局推一份整包（6–36 GB）且从不回收，11 款累到 140 GB，自检转 Air 排队 2716 秒超时 0 结论。
set -u
P=${1:?packs 目录}; G=${2:?款}; NEED=${3:?包 GB}; FLOOR=${S2A_PACKS_FLOOR_GB:-40}
cd "$P" 2> /dev/null || exit 0
trap '' HUP   # 调度端超时 / 断开 ssh 时不把删到一半的目录丢下（#799）
# 删除先改名成 .del_<款>.<pid>、去掉 .used 标记再删：被掐断也只留下点开头的残骸，不会被当成这款的包；下次先清残骸
for x in .del_*; do [ -d "$x" ] && { chmod -R u+w "$x" 2> /dev/null; rm -rf -- "$x"; }; done
# 可用 GB；单测注入 S2A_PACKS_FREE_CMD（打印可用 GB 的命令）
free() { if [ -n "${S2A_PACKS_FREE_CMD:-}" ]; then bash -c "$S2A_PACKS_FREE_CMD"; else df -k . | tail -1 | awk '{printf "%d", $4/1048576}'; fi; }
a=$(free); [ $(( a - NEED )) -ge "$FLOOR" ] && exit 0
busy=" "; for l in ../jobs/*/pack; do [ -L "$l" ] && busy="$busy$(basename "$(readlink "$l")") "; done
lst=; for g in *; do [ -d "$g" ] && [ "$g" != "$G" ] || continue; case $busy in *" $g "*) continue;; esac   # case 不放进 $( )：macOS 自带 bash 3.2 解析不了
  lst="$lst$(stat -f %m ".used_$g" 2> /dev/null || stat -f %m "$g") $g
"; done
order=$(printf '%s' "$lst" | sort -n | awk '{print $2}')
out=
for g in $order; do [ $(( $(free) - NEED )) -ge "$FLOOR" ] && break
  mv -- "$g" ".del_$g.$$" && rm -f ".used_$g" && { chmod -R u+w ".del_$g.$$" 2> /dev/null; rm -rf -- ".del_$g.$$"; } || { echo "【红】资源包回收：删不掉 $g"; exit 1; }; out="$out $g"; done
echo "资源包缓存回收：清掉${out:- 无}；可用 $a → $(free) GB（这份 $NEED GB，余量线 $FLOOR GB）"
[ $(( $(free) - NEED )) -ge "$FLOOR" ] || echo "【黄】清完仍不够余量线：可用 $(free) GB − 这份 $NEED GB < $FLOOR GB"
exit 0
