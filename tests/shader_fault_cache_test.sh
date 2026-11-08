#!/bin/bash
# 门禁覆盖：#723 P1 着色器取码失败负缓存（compat/tree/src/Ryujinx.Graphics.Gpu/Shader/S2AShaderFaultCache.cs + tests/shader_fault_cache/*）
# 纯逻辑单测（不引 Ryujinx 工程、不起游戏）：失效三条件、上限淘汰、同键重记不泄漏、第二次派发不调解码器。约 10 秒：bash tests/shader_fault_cache_test.sh
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d)
MSBUILDDISABLENODEREUSE=1 timeout 300 dotnet run -c Release --project "$H/tests/shader_fault_cache/S2A.ShaderFaultCacheTest.csproj" --artifacts-path "$T/art" 2>&1 | tail -40; rc=${PIPESTATUS[0]}
rm -rf "$T"; exit $rc
