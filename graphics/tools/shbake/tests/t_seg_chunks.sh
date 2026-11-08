#!/bin/bash
# 免解读缓存分块存储单测（Ryujinx 补丁 seg-chunks，10-24 帧率能耗线）：编 tests/segchunks（S2A.SegChunksTest）并跑；产物与中间件在 <仓库根>/build/segchunks_test。退出 0 = 全过
set -u
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../../../.." && pwd); OUT=$ROOT/build/segchunks_test
mkdir -p "$OUT"
timeout 500 dotnet build "$HERE/segchunks/S2A.SegChunksTest.csproj" -c Release --artifacts-path "$OUT/art" -v quiet -nologo > "$OUT/build.log" 2>&1 || { tail -30 "$OUT/build.log"; echo "期望 编过 → 真结果 编译失败 ✗"; exit 2; }
B=$(find "$OUT/art/bin/S2A.SegChunksTest" -name S2A.SegChunksTest.dll | head -1)
[ -n "$B" ] || { echo "期望 有 S2A.SegChunksTest.dll → 真结果 没找到 ✗"; exit 2; }
timeout 60 dotnet "$B"
