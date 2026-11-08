#!/bin/bash
# 门禁覆盖：compat/tree/src/Ryujinx.Graphics.Gpu/Shader/S2APipelineWarm.cs、Shader/ShaderSpecializationList.cs、Shader/ShaderCache.cs、
#   Shader/DiskCache/DiskCacheHostStorage.cs、Ryujinx.Graphics.Vulkan/VulkanRenderer.cs、Vulkan/ShaderCollection.cs、tests/pso_warm_gate/*
# 加载屏预热后端门控 / 总预算单测（tests/pso_warm_gate/Program.cs）：只有 DisableHostProgramPrefetch 的后端（安卓 Vulkan）实化热表分组并等待；
#   苹果后端（无策略 / false）不实化、不等待（负控）；整批共用总预算，用尽后停止等待并标记；失败 / 超时单独计数。
#   桩渲染器策略 + 桩程序，不建宿主资源。约 1 分钟：bash tests/pso_warm_gate_test.sh
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); LOG=$T/run.log
MSBUILDDISABLENODEREUSE=1 timeout 600 dotnet run -c Release --project "$H/tests/pso_warm_gate/PsoWarmGateTest.csproj" --artifacts-path "$T/art" > "$LOG" 2>&1; rc=$?
if [ $rc = 0 ]; then grep -E '^[✓✗] |^pso_warm_gate：' "$LOG"; else echo "🔴 pso_warm_gate 退出 ${rc}："; tail -30 "$LOG"; fi
rm -rf "$T"; exit $rc
