#!/bin/bash
# 片元输出类型变体单测（graphics/tools/shbake/FoutSelfTest.cs：按特化管线表观测补 FragmentOutputTypes 变体，期望值手算）：编 shbake 到仓外目录后跑 selftest-fout。退出 0 = 全过
#   T_FOUT_BAKE=<另一份 S2A.ShBake>：用它出包（反证：给旧版应红）
set -u
R=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)
O=${T_FOUT_OUT:-$R/build/t_fout}; mkdir -p "$O"
dotnet build -c Release "$R/graphics/tools/shbake/S2A.ShBake.csproj" --artifacts-path "$O/art" -p:OutDir="$O/bin/" > "$O/build.log" 2>&1 || { echo "编 S2A.ShBake 失败（$O/build.log）"; tail -5 "$O/build.log"; exit 1; }
timeout 300 "$O/bin/S2A.ShBake" selftest-fout ${T_FOUT_BAKE:+"$T_FOUT_BAKE"}; rc=$?
exit $rc
