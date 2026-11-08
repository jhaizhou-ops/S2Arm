#!/bin/bash
# VVL 图像附件访问状态宿主回归。
set -u
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../../../.." && pwd); OUT=$ROOT/build/vvl_sync_test
mkdir -p "$OUT"
timeout 400 dotnet build "$HERE/vvl-sync/S2A.VvlSyncTest.csproj" -c Release --artifacts-path "$OUT/art" -v quiet -nologo > "$OUT/build.log" 2>&1 || { tail -30 "$OUT/build.log"; exit 2; }
B=$(find "$OUT/art/bin/S2A.VvlSyncTest" -name S2A.VvlSyncTest.dll | head -1)
[ -n "$B" ] || exit 2
timeout 60 dotnet "$B"
