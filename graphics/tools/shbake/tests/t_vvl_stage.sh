#!/bin/bash
# VVL 着色器资源阶段布局与 Metal 能力表宿主回归。
set -u
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../../../.." && pwd); OUT=$ROOT/build/vvl_stage_test
mkdir -p "$OUT"
timeout 400 dotnet build "$HERE/vvl-stage/S2A.VvlStageTest.csproj" -c Release --artifacts-path "$OUT/art" -v quiet -nologo > "$OUT/build.log" 2>&1 || { tail -30 "$OUT/build.log"; exit 2; }
B=$(find "$OUT/art/bin/S2A.VvlStageTest" -name S2A.VvlStageTest.dll | head -1)
[ -n "$B" ] || exit 2
timeout 60 dotnet "$B"
