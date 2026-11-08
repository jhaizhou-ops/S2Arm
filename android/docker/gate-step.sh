#!/usr/bin/env bash
# Preserve the failing command's diagnostic before the wrapper's timing footer.
s2a_apk_step() {
  local log rc reason
  log=$(mktemp)
  rc=0
  "$@" > "$log" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    reason=$(grep -m1 -E '【红】|🔴|[Ee]rror:|^Execution failed|^> ' "$log" || true)
    [ -n "$reason" ] || reason=$(grep -v '^[[:space:]]*$' "$log" | tail -1 || true)
    printf '【红】APK %s 失败（rc=%s）：%s\n' "$1" "$rc" "${reason:-无诊断输出}" >&2
  fi
  cat "$log"
  rm -f "$log"
  return "$rc"
}
