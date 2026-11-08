#!/bin/bash
# 门禁覆盖：graphics/metal/gal_spill.c graphics/metal/gal_spill.h graphics/metal/gal_spill.m graphics/metal/gal_prog.m graphics/metal/Makefile tests/spill_lib_test.sh tests/spill_lib_test.py tests/fixtures/spill/
# 计算核共享内存溢出改写库单测（#783：gal_spill.c 不引 Metal，Linux / Windows 出包机与颜色出口改写、SPIR-V 加固一起编成小库，S2A.Dsh 的 NxgalSpvCross.SpillFix 照旧 DllImport("nxgal")）：
#   bash tests/spill_lib_test.sh
# Linux 编 make -C graphics/metal 的 build/gal/linux/libnxgal.so；Mac 先编整库 build/gal/libnxgal.dylib，再编同一个 linux 目标（.c 当纯 C 单独编，守住「.c 不引 Metal」），两份都比。
#   都用 ctypes 调 nxgal_dmsh_spill（槽号 27，同 Dsh.cs SPILL_SLOT），对 tests/fixtures/spill/ 六段原创计算核 MSL 逐字节比 .expected（首行 rc / 每线程组字节，其后改写结果或报错原因）。
#   夹具出自 graphics/tools/direct/tests/t_dmsh_spill.py 的同一模板：超限 / 不超限 / 恰好 32 KB / 认不出 / 两个数组只挪最大的 / 多种屏障与原子。
# 金样 = 搬移前（main 8035abaef）gal_prog.m 里的溢出改写（第 196–293 行）当 C 编、无设备（上限 GAL_TG_MEM_MAX，同离线出库）对同一输入的输出。
#   Mac 上整库有设备时上限按 MTLDevice 查询（gal_prog.m gal_spill_limit），本单测不建设备，比的同样是无设备那条路。
# 反证：金样改一个字节必须判不等；修前 linux 目标没有 nxgal_dmsh_spill，本单测即红。
set -u
R=$(cd "$(dirname "$0")/.." && pwd)
LIBS=("$R/build/gal/linux/libnxgal.so"); [ "$(uname -s)" = Darwin ] && LIBS=("$R/build/gal/libnxgal.dylib" "${LIBS[@]}")
LOG=$(mktemp); trap 'rm -f "$LOG"' EXIT
for LIB in "${LIBS[@]}"; do
  make -s -C "$R/graphics/metal" "$LIB" > "$LOG" 2>&1 || { echo "🔴 共享内存溢出改写库：编不出 ${LIB}：$(tail -1 "$LOG" | cut -c1-200)"; exit 1; }
  python3 "$R/tests/spill_lib_test.py" "$LIB" "$R/tests/fixtures/spill" || exit 1
done
