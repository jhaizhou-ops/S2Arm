#!/bin/bash
# 门禁手动：辅助脚本（构建辅助），首次要 --restore 联网恢复 NuGet，之后离线发布 GcBench NativeAOT，本身不是单测
# Explicit dependency preparation: bash tests/gcbench/build.sh --restore
# Subsequent offline build: bash tests/gcbench/build.sh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
DOTNET=${S2A_DOTNET:-$HOME/.dotnet/dotnet}
OUT=${S2A_GCBENCH_BUILD:-$ROOT/build/195-gcbench/aot}
[ -x "$DOTNET" ] || { echo '.NET 10 SDK missing; set S2A_DOTNET' >&2; exit 2; }
export DOTNET_ROOT
DOTNET_ROOT=$(dirname "$DOTNET")
export DEVELOPER_DIR=${S2A_DEVELOPER_DIR:-${DEVELOPER_DIR:-$(xcode-select -p)}}   # 按用户机器：指定 > 环境 > xcode-select（10-25，不写死 Xcode.app）
mkdir -p "$OUT"
opts=(--no-restore)
if [ "${S2A_GCBENCH_SERVER:-0}" = 1 ]; then
  opts+=(-p:ServerGarbageCollection=true)
fi
if [ "${1:-}" = --restore ]; then
  "$DOTNET" restore "$ROOT/tests/gcbench/GcBench.csproj" -r osx-arm64 \
    -p:BaseIntermediateOutputPath="$OUT/obj/" -p:MSBuildProjectExtensionsPath="$OUT/obj/"
elif [ "$#" != 0 ]; then echo 'Usage: build.sh [--restore]' >&2; exit 2; fi
"$DOTNET" publish "$ROOT/tests/gcbench/GcBench.csproj" -c Release -r osx-arm64 "${opts[@]}" \
  -p:BaseIntermediateOutputPath="$OUT/obj/" -p:MSBuildProjectExtensionsPath="$OUT/obj/" \
  -p:BaseOutputPath="$OUT/bin/" -o "$OUT/publish"
