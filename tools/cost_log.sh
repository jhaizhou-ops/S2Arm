#!/bin/bash
# 公开仓薄壳：cost_log.sh 是维护方私仓工具（测试成本账本），不随公开仓发布。
#   设 S2A_PRIVATE_TOOLS=<私仓 tools 目录> → 原样转给那一份（source / 直接执行都转）；
#   没设 → 不记账：cost_log 为空操作
_s2a_priv=${S2A_PRIVATE_TOOLS:+$S2A_PRIVATE_TOOLS/cost_log.sh}
if [ -n "$_s2a_priv" ] && [ -f "$_s2a_priv" ]; then
  if [ "${BASH_SOURCE[0]}" != "$0" ]; then source "$_s2a_priv" "$@"; return $?; fi
  exec bash "$_s2a_priv" "$@"
fi
cost_log() { :; }
if [ "${BASH_SOURCE[0]}" != "$0" ]; then return 0; fi
exit 0
