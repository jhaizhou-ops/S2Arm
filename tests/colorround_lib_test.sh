#!/bin/bash
# 门禁覆盖：graphics/metal/gal_colorround.c graphics/metal/gal_colorround.h graphics/metal/gal_colorround.m graphics/metal/Makefile tests/colorround_lib_test.sh tests/colorround_lib_test.py tests/fixtures/colorround/
# 颜色出口改写库单测（#783：gal_colorround.c 不引 Metal，Linux / Windows 出包机单独编成小库，S2A.Dsh 的 NxgalSpvCross.ColorRound 照旧 DllImport("nxgal")）：
#   bash tests/colorround_lib_test.sh
# Linux 编 make -C graphics/metal 的 build/gal/linux/libnxgal.so（只含这一份源码）；Mac 先编整库 build/gal/libnxgal.dylib，再编同一个 linux 目标（.c 当纯 C 单独编，
#   守住「.c 不引 Metal」，#1341 审），两份都比。都用 ctypes 调 nxgal_dmsh_color_round
#   （与 ColorRound 同一导出、同一 nxgal_dmsh_xc_free 释放），对 tests/fixtures/colorround/ 七段原创片元 MSL 逐字节比 .expected。
# 金样 = 搬移前（main 96909ab26）的 gal_colorround.m 当 C 编、对同一输入的输出；Linux 与 Mac 比同一份金样，即两边同一输入逐字节相同。
# 反证：金样改一个字节必须判不等；修前没有 linux 目标，本单测编不出库即红。
set -u
R=$(cd "$(dirname "$0")/.." && pwd)
LIBS=("$R/build/gal/linux/libnxgal.so"); [ "$(uname -s)" = Darwin ] && LIBS=("$R/build/gal/libnxgal.dylib" "${LIBS[@]}")
LOG=$(mktemp); trap 'rm -f "$LOG"' EXIT
for LIB in "${LIBS[@]}"; do
  make -s -C "$R/graphics/metal" "$LIB" > "$LOG" 2>&1 || { echo "🔴 颜色出口改写库：编不出 ${LIB}：$(tail -1 "$LOG" | cut -c1-200)"; exit 1; }
  python3 "$R/tests/colorround_lib_test.py" "$LIB" "$R/tests/fixtures/colorround" || exit 1
done
