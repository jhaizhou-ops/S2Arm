#!/bin/sh
# PipelineStatePreference 宿主单测：旧无状态记录 vs 新有状态记录的合并，含 has=0 负控。
set -eu
DOTNET=${DOTNET:-dotnet}
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$HERE/../../../.."
"$DOTNET" build graphics/tools/shbake/tests/state/S2A.StateTest.csproj -c Release --nologo -v:q
"$DOTNET" graphics/tools/shbake/tests/state/bin/Release/net10.0/S2A.StateTest.dll
