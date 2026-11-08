#!/bin/bash
# 门禁覆盖：graphics/metal/gal_spvx.c graphics/metal/gal_spvx.h graphics/metal/gal_spvx.m graphics/metal/gal_log.h graphics/metal/Makefile tests/spvx_lib_test.sh tests/spvx_lib_test.py tests/fixtures/spvx/
# SPIR-V 加固库单测（#783：gal_spvx.c 不引 Metal，Linux / Windows 出包机与 gal_colorround.c 一起编成小库，S2A.Dsh 的 NxgalSpvCross.Harden 照旧 DllImport("nxgal")）：
#   bash tests/spvx_lib_test.sh
# Linux 编 make -C graphics/metal 的 build/gal/linux/libnxgal.so；Mac 先编整库 build/gal/libnxgal.dylib，再编同一个 linux 目标（.c 当纯 C 单独编，守住「.c 不引 Metal」），两份都比。
#   都用 ctypes 调 nxgal_spv_harden（直连口径，与 Harden 同一导出、同一 nxgal_spv_free 释放），对 tests/fixtures/spvx/ 五支原创着色器的 SPIR-V 逐字比 .expected.hex
#   （「unchanged」= 应返回 NULL、原样不改）。各支的 GLSL 源码与说明在同目录；.spv.hex 由 NDK r28b 的 glslc（shaderc v2022.3）--target-env=vulkan1.1 编出，过 spirv-val。
# 金样 = 搬移前（main d2cde7147）的 gal_spvx.m 当 C 编、计数关、对同一输入的输出；Linux 与 Mac 比同一份金样，即两边同一输入逐字节相同。
# 反证：金样改一个字必须判不等，加固过的金样不得等于输入；修前 linux 目标没有 nxgal_spv_harden，本单测即红。
set -u
R=$(cd "$(dirname "$0")/.." && pwd)
LIBS=("$R/build/gal/linux/libnxgal.so"); [ "$(uname -s)" = Darwin ] && LIBS=("$R/build/gal/libnxgal.dylib" "${LIBS[@]}")
LOG=$(mktemp); trap 'rm -f "$LOG"' EXIT
for LIB in "${LIBS[@]}"; do
  make -s -C "$R/graphics/metal" "$LIB" > "$LOG" 2>&1 || { echo "🔴 SPIR-V 加固库：编不出 ${LIB}：$(tail -1 "$LOG" | cut -c1-200)"; exit 1; }
  python3 "$R/tests/spvx_lib_test.py" "$LIB" "$R/tests/fixtures/spvx" || exit 1
done
