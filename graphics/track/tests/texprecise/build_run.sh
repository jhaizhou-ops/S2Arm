#!/bin/bash
# 贴图精确访问不相交即跳过单测（见 Program.cs 头）：编 TexPrecise 跑一次。产物进 <仓库根>/build/texprecise（不进仓）。退出码 0 = 全过
set -e
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../../../.." && pwd); OUT=$ROOT/build/texprecise
mkdir -p "$OUT"
timeout 900 dotnet build "$HERE/TexPrecise.csproj" -c Release -o "$OUT/bin" -v quiet -nologo ${RYU_TREE:+-p:RyuTree=$RYU_TREE} > "$OUT/build.log" 2>&1 || { tail -30 "$OUT/build.log"; exit 2; }
cd "$OUT/bin"
timeout 60 dotnet TexPrecise.dll
