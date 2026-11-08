#!/bin/bash
# 门禁覆盖：pack/nx_unpack/* tests/nx_unpack_ncz/* compat/packages/*
# nx_unpack 的 NCZ 还原单测（nsz / xcz，10-26 解包泛化）：编 tests/nx_unpack_ncz（直接编 pack/nx_unpack/Ncz.cs、Copies.cs）并跑，另核同一内容多份择一（CopyPick）；合成数据，不用游戏文件、不要密钥。
#   期望：整流 / 分块两种 NCZ 还原出的字节与合成的原 NCA 逐字节相同，截断的 NCZ 报错。产物在 <仓库根>/build/nx_unpack_ncz_test。退出 0 = 全过
set -u
H=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$H/.." && pwd); OUT=$ROOT/build/nx_unpack_ncz_test; mkdir -p "$OUT"
timeout 500 dotnet build "$H/nx_unpack_ncz/NczTest.csproj" -c Release --artifacts-path "$OUT/art" -v quiet -nologo > "$OUT/build.log" 2>&1 || { tail -30 "$OUT/build.log"; echo "不通 编译（期望编过）"; exit 1; }
B=$(find "$OUT/art/bin" -name NczTest.dll | head -1); [ -n "$B" ] || { echo "不通 没找到 NczTest.dll"; exit 1; }
timeout 120 dotnet "$B"
