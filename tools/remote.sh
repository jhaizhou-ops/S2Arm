#!/bin/bash
# 公开仓薄壳：remote.sh 是维护方私仓工具（派活到维护方远端机器（mini / Air）），不随公开仓发布。
#   设 S2A_PRIVATE_TOOLS=<私仓 tools 目录> → 原样转给那一份（source / 直接执行都转）；
#   没设 → 没有远端：--host 打印 local，其余退 125（调用方据此全在本机做）
_s2a_priv=${S2A_PRIVATE_TOOLS:+$S2A_PRIVATE_TOOLS/remote.sh}
if [ -n "$_s2a_priv" ] && [ -f "$_s2a_priv" ]; then
  if [ "${BASH_SOURCE[0]}" != "$0" ]; then source "$_s2a_priv" "$@"; return $?; fi
  exec bash "$_s2a_priv" "$@"
fi
if [ "${BASH_SOURCE[0]}" != "$0" ]; then return 0; fi
for a in "$@"; do [ "$a" = --host ] && [ $# -eq 1 ] && { echo local; exit 0; }; done
echo "没有远端（公开仓不带 tools/remote.sh；维护方设 S2A_PRIVATE_TOOLS）" >&2; exit 125
