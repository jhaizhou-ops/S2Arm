#!/usr/bin/env bash
# 门禁覆盖：compat/tree/src/Ryujinx.Graphics.Nvdec.Vp9/* tests/vp9_loop_filter_init/*
# VP9 托管解码器 NVDEC 路径的环路滤波阈值（libvpx vp9_loop_filter_init 的移植）：每级 lim / mblim / hev_thr 与 libvpx 公式逐字节一致，
# 且 Decoder.Decode 每帧都调它（每帧新建 Vp9Common，漏调就回到全 0 阈值、去块滤波几乎不生效）
set -euo pipefail
H=$(cd "$(dirname "$0")/.." && pwd -P)
P="$H/tests/vp9_loop_filter_init/Vp9LoopFilterInit.csproj"
export MSBUILDDISABLENODEREUSE=1
command -v dotnet >/dev/null || { echo 'missing .NET SDK' >&2; exit 75; }
# 接线：Decoder.Decode 在设好 Lf 字段之后、LoopFilterFrameInit 之前调 LoopFilterInit
D="$H/compat/tree/src/Ryujinx.Graphics.Nvdec.Vp9/Decoder.cs"
a=$(grep -n 'cm.Lf.ModeDeltas = pictureInfo.ModeDeltas;' "$D" | cut -d: -f1 || true); b=$(grep -n 'LoopFilter.LoopFilterInit(ref cm);' "$D" | cut -d: -f1 || true)
c=$(grep -n 'LoopFilter.LoopFilterFrameInit(ref cm' "$D" | head -1 | cut -d: -f1 || true)
[ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ] || { echo "vp9_loop_filter_init: Decoder.Decode 没在 LoopFilterFrameInit 之前调 LoopFilterInit（${a}/${b}/${c}）" >&2; exit 1; }
cd "$H/compat/tree"
dotnet build "$P" -c Release -m:1 -p:UseSharedCompilation=false --nologo -v q
exec dotnet "$H/tests/vp9_loop_filter_init/bin/Release/net10.0/Vp9LoopFilterInit.dll"
