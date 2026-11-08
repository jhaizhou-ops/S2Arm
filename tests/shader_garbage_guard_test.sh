#!/bin/bash
# 门禁覆盖：图形着色器垃圾代码防线（compat/tree/src/Ryujinx.Graphics.Gpu/Engine/Threed/StateUpdater.cs、Shader/ShaderCache.cs、Shader/GpuAccessor.cs、
#   Ryujinx.Memory/Tracking/MemoryTracking.cs S2ATrackPageInfo + tests/shader_garbage_guard/*）。真 GpuContext / StateUpdater / ShaderCache + 桩渲染器，
#   顶点着色器整段 0xFF（阶段号 15）：取图形着色器不抛、本组绘制跳过、红行恰一次且带现场字段。约 1–3 分钟（首编 Ryujinx.Graphics.Gpu）：bash tests/shader_garbage_guard_test.sh
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d)
MSBUILDDISABLENODEREUSE=1 timeout 900 dotnet build "$H/tests/shader_garbage_guard/ShaderGarbageGuardTest.csproj" -c Release -o "$T/bin" -v quiet -nologo > "$T/build.log" 2>&1 || { tail -30 "$T/build.log"; rm -rf "$T"; exit 2; }
(cd "$T/bin" && timeout 120 dotnet ShaderGarbageGuardTest.dll); rc=$?
rm -rf "$T"; exit $rc
