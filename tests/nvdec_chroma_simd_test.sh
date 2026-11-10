#!/usr/bin/env bash
# 门禁覆盖：compat/tree/src/Ryujinx.Graphics.Nvdec/Image/SurfaceReader.cs compat/tree/src/Ryujinx.Graphics.Nvdec/Image/SurfaceWriter.cs tests/nvdec_chroma_simd/*
# Nvdec 色度平面与块线性客体内存互转（ARM64 走 AdvSimd ZIP 快路径）必须与按 OffsetCalculator 逐像素摆放的结果逐字节一致
set -euo pipefail
H=$(cd "$(dirname "$0")/.." && pwd -P)
P="$H/tests/nvdec_chroma_simd/NvdecChromaSimd.csproj"
export MSBUILDDISABLENODEREUSE=1
command -v dotnet >/dev/null || { echo 'missing .NET SDK' >&2; exit 75; }
cd "$H/compat/tree"
dotnet build "$P" -c Release -m:1 -p:UseSharedCompilation=false --nologo -v q
exec dotnet "$H/tests/nvdec_chroma_simd/bin/Release/net10.0/NvdecChromaSimd.dll"
