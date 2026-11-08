#!/bin/bash
# 公开仓薄壳：mac_slot.sh 是维护方私仓工具（Mac 局 GPU 槽位仲裁），不随公开仓发布。
#   设 S2A_PRIVATE_TOOLS=<私仓 tools 目录> → 原样转给那一份（source / 直接执行都转）；
#   没设 → 同 mac_slot_frozen.sh：不排队，run / prio 直接执行命令
_s2a_priv=${S2A_PRIVATE_TOOLS:+$S2A_PRIVATE_TOOLS/mac_slot.sh}
if [ -n "$_s2a_priv" ] && [ -f "$_s2a_priv" ]; then
  if [ "${BASH_SOURCE[0]}" != "$0" ]; then source "$_s2a_priv" "$@"; return $?; fi
  exec bash "$_s2a_priv" "$@"
fi
mac_slot_acquire() { :; }
mac_slot_release() { :; }
if [ "${BASH_SOURCE[0]}" != "$0" ]; then return 0; fi
case ${1:-} in
  run|prio) shift; while [ $# -gt 0 ] && [ "$1" != -- ]; do shift; done; [ "${1:-}" = -- ] && shift; [ $# -gt 0 ] || exit 0; exec "$@";;
  *) exit 0;;
esac
