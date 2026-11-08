#!/bin/bash
# 门禁覆盖：pack/nx_unpack/* tests/nx_unpack_romfs/* compat/packages/*
# #633 合成 RomFS + 真 LibHac IVFC：数据损坏可降级，非法结构 / 非目标错误仍失败；无游戏与密钥。
set -u
H=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$H/.." && pwd)
OUT=$ROOT/build/nx_unpack_romfs_test; mkdir -p "$OUT"
timeout 500 dotnet build "$H/nx_unpack_romfs/RomfsTest.csproj" -c Release --artifacts-path "$OUT/art" -v quiet -nologo > "$OUT/build.log" 2>&1 || { tail -30 "$OUT/build.log"; echo "不通 编译（期望编过）"; exit 1; }
B=$(find "$OUT/art/bin" -name RomfsTest.dll | head -1); [ -n "$B" ] || { echo "不通 没找到 RomfsTest.dll"; exit 1; }
timeout 120 dotnet "$B"
