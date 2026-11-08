#!/bin/bash
# 构建的退出码与输出筛选分开（#414）。
# 原先 services/test.sh 在 set -euo pipefail 下把构建直接接进筛选管道：
#   命令成功但汇总是中文（「0 个错误」）或合法空输出时 grep 返回 1，整步提前退出，后续单测一句都不跑；
#   命令失败但诊断里没有英文汇总时，原退出码 42 / 124 被管道尾巴的 1 覆盖，诊断也被筛掉。
# 这里只做一件事：成败只看命令自己的退出码，筛选只决定打印什么。
#
# 用法：
#   bash services/build_output.sh run  <输出文件> <命令…>   跑命令、落输出，成功返回 0，失败返回命令原退出码
#   bash services/build_output.sh show <退出码> <输出文件>   命令已跑完时复用同一套判定与打印
#
# 打印口径：
#   成功 → 只打汇总行（编译错误行 + 「N Error(s)」计数行），筛不出就什么都不打，不算失败；
#   失败 → 汇总行 + 输出末 40 行（中文诊断、超时诊断都在这段里），一行不改地转到标准错误。
# 不强制英文汇总：中文成功既不判红也不补造汇总；不把整条链 || true 掉，失败仍然停在这里。
set -uo pipefail

# 汇总行：dotnet 的编译错误行（「… error CSxxxx」）与「N Error(s)」计数行。筛不出任何行是正常情况。
summary_lines() { grep -E " error |rror\(s\)" "$1" 2>/dev/null | sort -u || true; }

# 判成败并打印。$1 = 命令实际退出码，$2 = 输出文件；返回值 = 该退出码。
report() {
  local rc=$1 log=$2 sum
  sum=$(summary_lines "$log")
  if [ "$rc" = 0 ]; then
    if [ -n "$sum" ]; then printf '%s\n' "$sum"; fi
    return 0
  fi
  echo "🔴 服务层构建失败（命令退出码 ${rc}）；输出 ${log}（末 40 行）：" >&2
  if [ -n "$sum" ]; then printf '%s\n' "$sum" >&2; fi
  if [ -s "$log" ]; then tail -40 "$log" | sed 's/^/    | /' >&2; fi
  return "$rc"
}

mode=${1:-}; shift || true
case "$mode" in
  run)
    log=${1:?用法: build_output.sh run <输出文件> <命令…>}; shift
    [ "$#" -gt 0 ] || { echo "用法: build_output.sh run <输出文件> <命令…>" >&2; exit 2; }
    mkdir -p "${log%/*}" 2>/dev/null || true
    "$@" > "$log" 2>&1
    rc=$?
    report "$rc" "$log"
    exit $?
    ;;
  show)
    report "${1:?用法: build_output.sh show <退出码> <输出文件>}" "${2:?用法: build_output.sh show <退出码> <输出文件>}"
    exit $?
    ;;
  *)
    echo "用法: build_output.sh run <输出文件> <命令…> | show <退出码> <输出文件>" >&2
    exit 2
    ;;
esac
