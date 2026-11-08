#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 门禁只看：android/cs/video/tests/* compat/tree/src/Ryujinx.Graphics.Nvdec/* compat/tree/src/Ryujinx.Graphics.Video/* compat/tree/src/Ryujinx.Common/Logging/*
# Host factory contracts only; no native decoder, game asset or device invocation.
set -euo pipefail
# 物理路径（pwd -P）：.NET 把项目文件路径规范化成 realpath；macOS 上 /tmp 是
# /private/tmp 软链，逻辑路径规格与物理路径构建会裂成两套项目身份（NuGet 图谱
# 规格写空、ref 程序集写在一套路径名下却在另一套名下探查）。
here=$(cd "$(dirname "$0")" && pwd -P)
project="$here/VideoDecoderFactory.Tests.csproj"
repo=$(cd "$here/../../../.." && pwd -P)
# SDK selection follows cwd, not the absolute project path.
python3 "$here/check_composition.py"
cd "$repo/compat/tree"
command -v dotnet >/dev/null || { echo 'missing repository-pinned .NET SDK' >&2; exit 75; }
args=(-c Release -m:1 -p:UseSharedCompilation=false --nologo)
query_args=(-p:Configuration=Release -m:1 -nologo)
# Test-only override permits an isolated production-source mutation copy.
if [ -n "${S2A_VIDEO_FACTORY_NVDEC_PROJECT:-}" ]; then
    args+=("-p:NvdecProject=$S2A_VIDEO_FACTORY_NVDEC_PROJECT")
    query_args+=("-p:NvdecProject=$S2A_VIDEO_FACTORY_NVDEC_PROJECT")
fi
dotnet build "$project" "${args[@]}"
if ! target=$(dotnet msbuild "$project" "${query_args[@]}" -getProperty:TargetPath); then
    printf '%s\n' "$target" >&2
    exit 1
fi
[ -f "$target" ] || { echo 'built TargetPath missing' >&2; exit 1; }
# Fresh processes keep process-global factory-failure suppression independent.
for scenario in registered unregistered throwing android-registered; do
    dotnet "$target" "$scenario"
done
