#!/bin/bash
# 多线程渲染器等程序不自旋单测（Ryujinx 补丁 progq-wait-block，10-24 画面·着色器线）：编 tests/progqueue（S2A.ProgQueueTest）并跑；产物与中间件在 <仓库根>/build/progqueue_test。退出 0 = 全过
set -u
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../../../.." && pwd); OUT=$ROOT/build/progqueue_test
mkdir -p "$OUT"
timeout 500 dotnet build "$HERE/progqueue/S2A.ProgQueueTest.csproj" -c Release --artifacts-path "$OUT/art" -v quiet -nologo > "$OUT/build.log" 2>&1 || { tail -30 "$OUT/build.log"; echo "期望 编过 → 真结果 编译失败 ✗"; exit 2; }
B=$(find "$OUT/art/bin/S2A.ProgQueueTest" -name S2A.ProgQueueTest.dll | head -1)
[ -n "$B" ] || { echo "期望 有 S2A.ProgQueueTest.dll → 真结果 没找到 ✗"; exit 2; }
timeout 60 dotnet "$B"
