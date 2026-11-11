#!/usr/bin/env bash
# 门禁覆盖：compat/tree/src/Ryujinx.Audio/Renderer/Dsp/{ResamplerHelper,S2ADspMixHelper,S2ADspFast}.cs compat/tree/src/Ryujinx.Audio/Renderer/Dsp/Command/{DownMixSurroundToStereo,MixRamp,MixRampGrouped,VolumeRamp,DeviceSink}Command.cs tests/audio_dsp_simd/*
# 音频 DSP 内核的 S2Arm AdvSimd 快路径（S2A_AUDIO_DSP_FAST，缺省开）必须与上游标量循环逐位一致；
# 跑两遍：缺省（快路径开）与 S2A_AUDIO_DSP_FAST=0（快路径关），分派器接线两种模式都必须绿。
# 在非 ARM64 上没有 AdvSimd，只打印 off。
set -euo pipefail
H=$(cd "$(dirname "$0")/.." && pwd -P)
P="$H/tests/audio_dsp_simd/AudioDspSimd.csproj"
export MSBUILDDISABLENODEREUSE=1
command -v dotnet >/dev/null || { echo 'missing .NET SDK' >&2; exit 75; }
cd "$H/compat/tree"
dotnet build "$P" -c Release -m:1 -p:UseSharedCompilation=false --nologo -v q
BIN="$H/tests/audio_dsp_simd/bin/Release/net10.0/AudioDspSimd.dll"
dotnet "$BIN"
S2A_AUDIO_DSP_FAST=0 dotnet "$BIN"
