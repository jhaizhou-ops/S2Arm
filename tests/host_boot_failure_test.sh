#!/bin/bash
# 门禁覆盖：services/S2A.Services/Host.cs tests/host_boot_failure/
# Real filesystem failures through Host.Boot; no fake native layer or renderer.
set -euo pipefail
cd "$(dirname "$0")/.."
DOTNET=${DOTNET:-$HOME/.dotnet/dotnet}
"$DOTNET" build tests/host_boot_failure/HostBootFailure.csproj -c Release --nologo
"$DOTNET" tests/host_boot_failure/bin/Release/net10.0/HostBootFailure.dll
