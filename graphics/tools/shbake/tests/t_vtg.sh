#!/bin/bash
# 转计算程序进缓存单测（graphics/tools/shbake/VtgSelfTest.cs：保留布局重建、复合宿主二进制往返、磁盘缓存阶段掩码，期望值手算）：编 shbake 到仓外目录后跑 selftest-vtg。退出 0 = 全过
set -u
R=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)
O=${T_VTG_OUT:-$R/build/t_vtg}; mkdir -p "$O"
dotnet build -c Release "$R/graphics/tools/shbake/S2A.ShBake.csproj" --artifacts-path "$O/art" -p:OutDir="$O/bin/" > "$O/build.log" 2>&1 || { echo "编 S2A.ShBake 失败（$O/build.log）"; tail -5 "$O/build.log"; exit 1; }
timeout 120 "$O/bin/S2A.ShBake" selftest-vtg; rc=$?
exit $rc
