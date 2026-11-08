#!/bin/bash
# 公开仓薄壳：disk_low.sh 是维护方私仓工具（磁盘余量（含远端机器）），不随公开仓发布。
#   设 S2A_PRIVATE_TOOLS=<私仓 tools 目录> → 原样转给那一份（source / 直接执行都转）；
#   没设 → 只做本机：disk_free_g / disk_low / disk_need 按本机卷判，远端一律当没有
_s2a_priv=${S2A_PRIVATE_TOOLS:+$S2A_PRIVATE_TOOLS/disk_low.sh}
if [ -n "$_s2a_priv" ] && [ -f "$_s2a_priv" ]; then
  if [ "${BASH_SOURCE[0]}" != "$0" ]; then source "$_s2a_priv" "$@"; return $?; fi
  exec bash "$_s2a_priv" "$@"
fi
disk_free_g() { [ "${1:-local}" = local ] || return 0; [ -n "${S2A_DISK_FREE_G:-}" ] && { echo "$S2A_DISK_FREE_G"; return; }
  df -g "${S2A_DISK_PATH:-$HOME}" 2> /dev/null | awk 'NR == 2 { print $4 }'; }
disk_low() { local f m=${S2A_MIN_FREE_GB:-0}; [ "${1:-local}" = local ] || return 1
  f=$(disk_free_g); [ -n "$f" ] && [ "$f" -lt "$m" ] || return 1; echo "${2:+$2 }磁盘不足：可用 ${f} G < ${m} G"; return 0; }
disk_need() { local r=${S2A_ROOTS:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/roots} f
  while [ ! -e "$r" ] && [ "$r" != / ]; do r=$(dirname "$r"); done
  f=${S2A_DISK_FREE_G:-$(df -g "$r" 2> /dev/null | awk 'NR == 2 { print $4 }')}; [ -n "$f" ] || return 0
  [ "$f" -ge "${2:?GB}" ] && return 0
  echo "【红】${1:-?} 出包要 ${2} GB，产物根所在卷（${r}）只剩 ${f} GB：腾出空间后重新出包" >&2; return 1; }
if [ "${BASH_SOURCE[0]}" = "$0" ]; then disk_low; exit $?; fi
return 0 2> /dev/null || true
