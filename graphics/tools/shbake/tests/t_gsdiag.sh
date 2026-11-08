#!/bin/bash
# #1456 单点诊断门序与写出单测（graphics/tools/shbake/GsDiagSelfTest.cs：门关零输出零读、门开三类全落盘）：编 shbake 到仓外目录后跑 selftest-gsdiag。退出 0 = 全过
set -u
R=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)
O=${T_GSDIAG_OUT:-$R/build/t_gsdiag}; mkdir -p "$O"
dotnet build -c Release "$R/graphics/tools/shbake/S2A.ShBake.csproj" --artifacts-path "$O/art" -p:OutDir="$O/bin/" > "$O/build.log" 2>&1 || { echo "编 S2A.ShBake 失败（$O/build.log）"; tail -5 "$O/build.log"; exit 1; }
timeout 120 "$O/bin/S2A.ShBake" selftest-gsdiag; rc=$?
exit $rc
