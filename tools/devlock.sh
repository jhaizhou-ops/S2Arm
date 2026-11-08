#!/bin/bash
# 公开仓薄壳：devlock.sh 是维护方私仓工具（维护方真机锁），不随公开仓发布。
#   设 S2A_PRIVATE_TOOLS=<私仓 tools 目录> → 原样转给那一份（source / 直接执行都转）；
#   没设 → 报红退 2
_s2a_priv=${S2A_PRIVATE_TOOLS:+$S2A_PRIVATE_TOOLS/devlock.sh}
if [ -n "$_s2a_priv" ] && [ -f "$_s2a_priv" ]; then
  if [ "${BASH_SOURCE[0]}" != "$0" ]; then source "$_s2a_priv" "$@"; return $?; fi
  exec bash "$_s2a_priv" "$@"
fi
echo "【红】tools/devlock.sh 是维护方真机锁，不在公开仓（维护方设 S2A_PRIVATE_TOOLS）" >&2
if [ "${BASH_SOURCE[0]}" != "$0" ]; then return 2; fi
exit 2
