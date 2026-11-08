#!/bin/bash
# 门禁覆盖：compat/tree/src/Ryujinx.Memory/Range/MultiRange.cs compat/tree/src/Ryujinx.Graphics.Gpu/Image/TextureGroup.cs tests/multirange/*
# MultiRange.SliceOverlapsWith 单测（compat/tree/src/Ryujinx.Memory/Range/MultiRange.cs + Ryujinx.Graphics.Gpu/Image/TextureGroup.cs 的 ClearModified 用它）：
#   与 Slice(...).OverlapsWith(...) 逐例等价；多段时 1 万次零分配、旧写法有分配（反证）。约 20 秒：bash tests/multirange_test.sh
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d)
MSBUILDDISABLENODEREUSE=1 timeout 300 dotnet run -c Release --project "$H/tests/multirange/MultiRangeTest.csproj" --artifacts-path "$T/art" 2>&1 | tail -4; rc=${PIPESTATUS[0]}
rm -rf "$T"; exit $rc
