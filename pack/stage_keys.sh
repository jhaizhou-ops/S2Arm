#!/bin/bash
# 只算各阶段键、不出任何产物：pack/stage_keys.sh <款> <产物根>
#   用本树代码对指定产物根逐阶段算键（各 stage_*.sh 原样跑，roots.sh 的 S2A_ROOT_CUR / S2A_STAGE_KEYS 让它们记下键就退出），
#   每行打「阶段<TAB>本树算出的键<TAB>该根记的键」。tools/app_only.sh 据此判「这个提交改没改包里的预编产物」。
#   系统数据计入时区来源键；界面布局等对本款不适用、没走到判键的阶段不打行。
set -u
G=${1:?款}; B=$(cd -P "${2:?产物根}" 2> /dev/null && pwd) || { echo "【红】没有产物根 $2" >&2; exit 1; }
H=$(cd "$(dirname "$0")" && pwd); K=$(mktemp); trap 'rm -f "$K"' EXIT
for s in rewrite caps uilayout aoc romfsidx shaders; do S2A_ROOT_CUR=$B S2A_STAGE_KEYS=$K bash "$H/stage_$s.sh" "$G" > /dev/null 2>&1; done
S2A_ROOT_CUR=$B S2A_STAGE_KEYS=$K bash "$H/stage_sysdata.sh" "$G" > /dev/null 2>&1 || { echo '【红】系统数据时区来源键无法计算' >&2; exit 1; }
awk -F '\t' '$1=="sysdata" {n++; if (NF!=2 || $2=="") bad=1} END {exit !(n==1 && !bad)}' "$K" \
  || { echo '【红】系统数据时区来源键缺失或重复' >&2; exit 1; }
while IFS=$'\t' read -r s k; do
  recorded=$(cat "$B/.stage_$s" 2> /dev/null)
  # 没有生成器记录的旧真时区仍当真实数据；旧宿主生成目录必须重出。
  [ "$s" != sysdata ] || [ -n "$recorded" ] || [ "$k" != real ] || recorded=real
  printf '%s\t%s\t%s\n' "$s" "$k" "$recorded"
done < "$K"
