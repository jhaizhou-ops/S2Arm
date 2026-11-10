#!/usr/bin/env bash
# 门禁覆盖：compat/tree/src/Ryujinx.Graphics.Nvdec.Vp9/Dsp/Convolve.cs tests/vp9_convolve_simd/*
# VP9 8 抽头亚像素插值的跨平台向量路径（ARM64 走 AdvSimd）必须与标量逐字节一致；在 x86 上向量路径不启用，只打印 off
set -euo pipefail
H=$(cd "$(dirname "$0")/.." && pwd -P)
P="$H/tests/vp9_convolve_simd/Vp9ConvolveSimd.csproj"
export MSBUILDDISABLENODEREUSE=1
command -v dotnet >/dev/null || { echo 'missing .NET SDK' >&2; exit 75; }
cd "$H/compat/tree"
dotnet build "$P" -c Release -m:1 -p:UseSharedCompilation=false --nologo -v q
exec dotnet "$H/tests/vp9_convolve_simd/bin/Release/net10.0/Vp9ConvolveSimd.dll"
