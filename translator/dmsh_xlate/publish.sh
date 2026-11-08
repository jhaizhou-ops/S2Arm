#!/bin/bash
# Publish the tracked translator with normalized source/debug paths and its symbols.
set -euo pipefail
xlate_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
dotnet_root=${DOTNET_ROOT:-"$HOME/.dotnet"}
dotnet=${DOTNET:-"$dotnet_root/dotnet"}
if [ ! -x "$dotnet" ]; then
    echo "[RED] .NET SDK missing: install it with pack/jobs/applenv.py --install dotnet, or set DOTNET_ROOT / DOTNET" >&2
    exit 2
fi
export DOTNET_ROOT="$dotnet_root"
export DOTNET_PROCESSOR_COUNT=2 MSBUILDDISABLENODEREUSE=1
exec "$dotnet" publish "$xlate_dir/dmsh_xlate.csproj" \
    -c Release --self-contained false -m:2 -nodeReuse:false \
    -p:UseSharedCompilation=false -p:NuGetAudit=false \
    -p:ContinuousIntegrationBuild=true \
    -o "$xlate_dir/../dmsh_xlate_bin"
