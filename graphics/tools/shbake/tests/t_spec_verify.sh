#!/bin/bash
# 包内特化核对单测（Ryujinx 补丁 shader-spec-verify，10-21）：编 tests/spec（S2A.SpecTest）并跑；产物与中间件在 <仓库根>/build/spec_test（不往 compat/tree 写 obj）。退出 0 = 全过
set -u
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../../../.." && pwd); OUT=$ROOT/build/spec_test
mkdir -p "$OUT"
timeout 500 dotnet build "$HERE/spec/S2A.SpecTest.csproj" -c Release --artifacts-path "$OUT/art" -v quiet -nologo > "$OUT/build.log" 2>&1 || { tail -30 "$OUT/build.log"; echo "期望 编过 → 真结果 编译失败（$OUT/build.log）✗"; exit 2; }
B=$(find "$OUT/art/bin/S2A.SpecTest" -name S2A.SpecTest.dll | head -1)
[ -n "$B" ] || { echo "期望 有 S2A.SpecTest.dll → 真结果 没找到 ✗"; exit 2; }
timeout 60 dotnet "$B"
