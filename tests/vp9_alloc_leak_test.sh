#!/usr/bin/env bash
# 门禁覆盖：compat/tree/src/Ryujinx.Graphics.Nvdec.Vp9/* tests/vp9_alloc_leak/*
# VP9 托管解码器每帧缓冲不泄漏（11-07 GRID Autosport 开场视频：解码失败的帧不还池，之后每帧池外分配永不释放，宿主实占每帧约 +2 MB 到 8 GB 被杀）；只跑解码器本身
set -euo pipefail
H=$(cd "$(dirname "$0")/.." && pwd -P)
P="$H/tests/vp9_alloc_leak/Vp9AllocLeak.csproj"
export MSBUILDDISABLENODEREUSE=1
command -v dotnet >/dev/null || { echo 'missing .NET SDK' >&2; exit 75; }
cd "$H/compat/tree"   # SDK（global.json）与包源（nuget.config）跟当前目录走
dotnet build "$P" -c Release -m:1 -p:UseSharedCompilation=false --nologo -v q
exec dotnet "$H/tests/vp9_alloc_leak/bin/Release/net10.0/Vp9AllocLeak.dll"
