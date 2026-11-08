#!/bin/bash
# VVL 统一缓冲范围与不足报红宿主回归。
set -u
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../../../.." && pwd); OUT=$ROOT/build/vvl_clamp_test
mkdir -p "$OUT"
timeout 400 dotnet build "$HERE/vvl-clamp/S2A.VvlClampTest.csproj" -c Release --artifacts-path "$OUT/art" -v quiet -nologo > "$OUT/build.log" 2>&1 || { tail -30 "$OUT/build.log"; exit 2; }
B=$(find "$OUT/art/bin/S2A.VvlClampTest" -name S2A.VvlClampTest.dll | head -1)
[ -n "$B" ] || exit 2
timeout 60 dotnet "$B"
