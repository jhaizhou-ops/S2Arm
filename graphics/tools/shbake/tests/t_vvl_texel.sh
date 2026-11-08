#!/bin/bash
# VVL texel 视图对齐影子与采样器线性滤波降级宿主回归。
set -u
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../../../.." && pwd); OUT=$ROOT/build/vvl_texel_test
mkdir -p "$OUT"
timeout 400 dotnet build "$HERE/vvl-texel/S2A.VvlTexelTest.csproj" -c Release --artifacts-path "$OUT/art" -v quiet -nologo > "$OUT/build.log" 2>&1 || { tail -30 "$OUT/build.log"; exit 2; }
B=$(find "$OUT/art/bin/S2A.VvlTexelTest" -name S2A.VvlTexelTest.dll | head -1)
[ -n "$B" ] || exit 2
timeout 60 dotnet "$B"
