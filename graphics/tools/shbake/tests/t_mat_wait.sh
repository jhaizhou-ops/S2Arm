#!/bin/bash
# 按需实化不等渲染线程单测（graphics/tools/shbake/MatWaitSelfTest.cs：真多线程渲染器 + 假后端，渲染线程卡在一支现编上时实化缓存程序、补查链接，期望值手算）：
#   编 shbake 到仓外目录后跑 selftest-matwait。退出 0 = 全过
set -u
R=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)
O=${T_VTG_OUT:-$R/build/t_vtg}; mkdir -p "$O"
# 各段耗时与退出码进日志末行（10-25：门禁里整步 120 秒超时（退出 124）近期 46 次 12 次，日志被下一轮覆盖，分不清是编译慢还是自检挂住）
t0=$SECONDS
dotnet build -c Release "$R/graphics/tools/shbake/S2A.ShBake.csproj" --artifacts-path "$O/art" -p:OutDir="$O/bin/" > "$O/build.log" 2>&1 || { echo "编 S2A.ShBake 失败（$O/build.log）"; tail -5 "$O/build.log"; exit 1; }
tb=$((SECONDS - t0)); echo "t_mat_wait 分段：编译 ${tb} 秒，开始自检"
t0=$SECONDS; timeout 60 "$O/bin/S2A.ShBake" selftest-matwait; rc=$?
to=; [ "$rc" = 124 ] && to='，自检 60 秒超时'
echo "t_mat_wait 分段：编译 ${tb} 秒、自检 $((SECONDS - t0)) 秒（退出 ${rc}${to}）"
exit $rc
