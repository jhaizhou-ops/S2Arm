#!/usr/bin/env bash
# 门禁覆盖：compat/tree/src/Ryujinx.Graphics.Nvdec.Vp9/* compat/tree/src/Ryujinx.Graphics.Video/* tests/vp9_coef_counts/*
# VP9 托管解码器回写给客体驱动的系数 / EOB 分支计数（11-07 GRID Autosport 开场视频绿屏：计数写进防御性副本、全 0）；只跑解码器本身，不碰原生层与游戏资源
set -euo pipefail
H=$(cd "$(dirname "$0")/.." && pwd -P)
P="$H/tests/vp9_coef_counts/Vp9CoefCounts.csproj"
export MSBUILDDISABLENODEREUSE=1
command -v dotnet >/dev/null || { echo 'missing .NET SDK' >&2; exit 75; }
cd "$H/compat/tree"   # SDK（global.json）与包源（nuget.config）跟当前目录走
dotnet build "$P" -c Release -m:1 -p:UseSharedCompilation=false --nologo -v q
exec dotnet "$H/tests/vp9_coef_counts/bin/Release/net10.0/Vp9CoefCounts.dll"
