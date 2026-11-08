#!/bin/bash
# 多段映射不压段单测（见 Program.cs 头）：编 VrcSplit 跑一次。产物进 <仓库根>/build/vrcsplit（不进仓）。退出码 0 = 全过；死锁时进程 3 秒后自己判失败退出
set -e
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../../../.." && pwd); OUT=$ROOT/build/vrcsplit
mkdir -p "$OUT"
timeout 900 dotnet build "$HERE/VrcSplit.csproj" -c Release -o "$OUT/bin" -v quiet -nologo ${RYU_TREE:+-p:RyuTree=$RYU_TREE} > "$OUT/build.log" 2>&1 || { tail -30 "$OUT/build.log"; exit 2; }
cd "$OUT/bin"
timeout 60 dotnet VrcSplit.dll
