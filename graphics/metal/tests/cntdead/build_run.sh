#!/bin/bash
# 计数结果回调换线程单测：编 libnxgal.dylib 与 CntDead 并跑。产物进 <仓库根>/build/cntdead（不进仓）
set -e
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../../../.." && pwd); OUT=$ROOT/build/cntdead
mkdir -p "$OUT"
make -s -C "$ROOT/graphics/metal" "$ROOT/build/gal/libnxgal.dylib"
timeout 600 dotnet build "$HERE/CntDead.csproj" -c Release --artifacts-path "$OUT/art" -p:OutDir="$OUT/bin/" -v quiet -nologo > "$OUT/build.log" 2>&1 || { grep -E ' error ' "$OUT/build.log" | sort -u | head -20; exit 2; }
cd "$OUT/bin" && NXGAL_LIB="$ROOT/build/gal/libnxgal.dylib" timeout 60 dotnet CntDead.dll
