#!/usr/bin/env bash
# 门禁覆盖：compat/tree/src/Ryujinx.Graphics.Nvdec/Vp9NativeFrame.cs android/codecs/vpxbench/hdr.c android/codecs/vpxbench/hdr.h tests/vp9_native_frame/*
# 原生 VP9 的帧头与参考槽（docs/设计_原生VP9/design_phase2_B.md §2-§3）：游戏里跑的 C# 版（Vp9NativeFrame.cs）与手机测速、libvpx 补丁对拍用的
# C 版（android/codecs/vpxbench/hdr.c）喂同一批随机 NVDEC 作业序列，回退判定、刷新的槽、写出的帧（帧头 + 占位字节 + tile 数据）逐字节一致。
set -euo pipefail
H=$(cd "$(dirname "$0")/.." && pwd -P)
export MSBUILDDISABLENODEREUSE=1
command -v dotnet >/dev/null || { echo 'missing .NET SDK' >&2; exit 75; }
CC=${CC:-cc}; command -v "$CC" >/dev/null || { echo "missing C compiler ($CC)" >&2; exit 75; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
"$CC" -std=c11 -O2 -I"$H/android/codecs/vpxbench" "$H/tests/vp9_native_frame/hdrcheck.c" "$H/android/codecs/vpxbench/hdr.c" -o "$W/hdrcheck"
cd "$H/compat/tree"   # SDK（global.json）与包源（nuget.config）跟当前目录走
dotnet build "$H/tests/vp9_native_frame/Vp9NativeFrameCheck.csproj" -c Release -m:1 -p:UseSharedCompilation=false --nologo -v q
exec dotnet "$H/tests/vp9_native_frame/bin/Release/net10.0/Vp9NativeFrameCheck.dll" "$W/hdrcheck" "$W"
