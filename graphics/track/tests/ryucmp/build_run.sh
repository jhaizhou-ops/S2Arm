#!/bin/bash
# 写跟踪对拍：编 libcmp.dylib（track.c + cmp_native.c）与 RyuCmp，跑 <种子> <轮数>。产物进 <仓库根>/build/ryucmp（不进仓）
set -e
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../../../.." && pwd); OUT=$ROOT/build/ryucmp
mkdir -p "$OUT"
clang -O2 -dynamiclib -o "$OUT/libcmp.dylib" "$HERE/cmp_native.c" "$ROOT/graphics/track/track.c"
timeout 900 dotnet build "$HERE/RyuCmp.csproj" -c Release -o "$OUT/bin" -v quiet -nologo > "$OUT/build.log" 2>&1 || { tail -30 "$OUT/build.log"; exit 2; }
cp "$OUT/libcmp.dylib" "$OUT/bin/"
cd "$OUT/bin" && timeout 600 dotnet RyuCmp.dll "${1:-1}" "${2:-2000}"
