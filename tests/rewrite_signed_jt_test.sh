#!/bin/bash
# 紧凑跳转表：ldrsb/ldrsh 与 sxtb/sxth/sxtw 的负偏移。合成指令，不使用游戏文件。
# 门禁覆盖：runtime/rewriter/* pack/rewriter.py tests/rewrite_golden.py tests/fixtures/rewrite_golden/* tests/rewrite_signed_jt_exec.c
# 缺省 S2A_REWRITE_SIGNED_JT 不设（关）：无符号形态与打开前相同。打开后负偏移落点按硬件铺。
# 没有 llvm-objcopy / llvm-nm（含 Homebrew LLVM）时，打印「跳过：无 objcopy」并退出 75（门禁记环境未就绪，不当绿；mini 与本机门禁都有 /opt/homebrew/opt/llvm/bin，11-01 核）。
# 没有 qemu 或 aarch64 gcc 时，执行段记「跳过」，不因此失败。
# REW_C 未设置时按出包同一入口取（pack/rewriter.py c-path），与 rewrite_c_gate_test.sh 相同；取不到判红。产物对金样（tests/rewrite_golden.py）。
set -euo pipefail
H=$(cd "$(dirname "$0")/.." && pwd)
PY=${S2A_PY:-${PY:-$HOME/.s2arm/venv/bin/python3}}
[ -x "$PY" ] || PY=python3
export PY
# 与 tests/rewrite_signed_jt_test.py 的 find_objcopy_nm 同一组名字。一对都没有就跳过，不去编 C 改写器。
probe() {
  local n=$1 d
  [ -n "$n" ] || return 1
  [ -x "$n" ] && return 0
  command -v "$n" >/dev/null 2>&1 && return 0
  for d in /opt/homebrew/opt/llvm/bin ${PATH//:/ }; do
    [ -x "$d/$n" ] && return 0
  done
  return 1
}
if ! { { probe llvm-objcopy && probe llvm-nm; } \
    || { probe /opt/homebrew/opt/llvm/bin/llvm-objcopy && probe /opt/homebrew/opt/llvm/bin/llvm-nm; } \
    || { probe "${AARCH64_OBJCOPY:-aarch64-linux-gnu-objcopy}" && probe "${AARCH64_NM:-aarch64-linux-gnu-nm}"; }; }; then
  echo "跳过：无 objcopy"
  exit 75
fi
if [ -z "${REW_C:-}" ]; then
  REW_C=$("$PY" "$H/pack/rewriter.py" c-path 2>/dev/null | tail -1)
  [ -x "${REW_C:-}" ] || { echo "🔴 取不到 C 改写器（python3 pack/rewriter.py c-path）"; exit 1; }
fi
export REW_C
exec "$PY" "$H/tests/rewrite_signed_jt_test.py"
