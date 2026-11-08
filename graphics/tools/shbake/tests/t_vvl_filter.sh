#!/bin/bash
# VVL 采样器线性滤波降级宿主回归。
set -u
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../../../.." && pwd); OUT=$ROOT/build/vvl_filter_test
mkdir -p "$OUT"
timeout 400 dotnet build "$HERE/vvl-filter/S2A.VvlFilterTest.csproj" -c Release --artifacts-path "$OUT/art" -v quiet -nologo > "$OUT/build.log" 2>&1 || { tail -30 "$OUT/build.log"; exit 2; }
B=$(find "$OUT/art/bin/S2A.VvlFilterTest" -name S2A.VvlFilterTest.dll | head -1)
[ -n "$B" ] || exit 2
timeout 60 dotnet "$B"
