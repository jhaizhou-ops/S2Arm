#!/bin/bash
# Actual Vulkan timing helpers and the cache-generation counter, with no GPU.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../../.." && pwd)
OUT=${1:-"$ROOT/build/tests/vulkan-diag"}
mkdir -p "$OUT"
cat > "$OUT/NuGet.Config" <<'XML'
<configuration><packageSources><clear /></packageSources></configuration>
XML
dotnet restore "$HERE/VulkanDiag.csproj" --configfile "$OUT/NuGet.Config" --artifacts-path "$OUT/art" -p:NuGetAudit=false > "$OUT/build.log" 2>&1
dotnet build "$HERE/VulkanDiag.csproj" -c Release --no-restore --artifacts-path "$OUT/art" >> "$OUT/build.log" 2>&1
DLL="$OUT/art/bin/VulkanDiag/release/VulkanDiag.dll"
env -u S2A_SHADER_CACHE_DIAG dotnet "$DLL"
S2A_SHADER_CACHE_DIAG=1 dotnet "$DLL"
# MountShaderPack runs with a frozen production profile and the optional APK asset absent (fixture: graphics/vulkan/runtime/tests/asset_fixture.c).
RUNTIME="$ROOT/graphics/vulkan/runtime/tests/Runtime.Tests.csproj"
dotnet restore "$RUNTIME" --configfile "$OUT/NuGet.Config" --artifacts-path "$OUT/runtime-art" -p:NuGetAudit=false >> "$OUT/build.log" 2>&1
dotnet build "$RUNTIME" -c Release --no-restore --artifacts-path "$OUT/runtime-art" >> "$OUT/build.log" 2>&1
RUNTIME_BIN="$OUT/runtime-art/bin/Runtime.Tests/release"
# APK 资产边界的替身 libs2arm_android 由 Runtime.Tests.csproj 构建时从 asset_fixture.c 生成（缺省 -2 = 资产不存在，带 s2a_test_asset_result）；
#   这里不再另编一份覆盖它（10-30：旧替身 missing_asset.c 没有 s2a_test_asset_result，覆盖后 ShaderPackFallbackChecks 抛 EntryPointNotFound → SIGABRT 134）
dotnet "$RUNTIME_BIN/Runtime.Tests.dll"
