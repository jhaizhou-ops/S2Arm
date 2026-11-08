#!/bin/bash
# 写跟踪 × GPFIFO 排空时机单测：编 libs2a_native.dylib（track.c + 对拍工具的信号处理 / 真内存 / 按字节写）与 FifoDrain 并跑。产物进 <仓库根>/build/fifodrain（不进仓）
set -e
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../../../.." && pwd); OUT=$ROOT/build/fifodrain
mkdir -p "$OUT"
clang -O2 -dynamiclib -o "$OUT/libs2a_native.dylib" "$HERE/../ryucmp/cmp_native.c" "$ROOT/graphics/track/track.c"
timeout 900 dotnet build "$HERE/FifoDrain.csproj" -c Release -o "$OUT/bin" -v quiet -nologo > "$OUT/build.log" 2>&1 || { tail -30 "$OUT/build.log"; exit 2; }
cp "$OUT/libs2a_native.dylib" "$OUT/bin/"
cd "$OUT/bin" && timeout 120 dotnet FifoDrain.dll
