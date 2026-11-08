#!/bin/bash
# Production shader cache queue and detached syncpoint callback; host only, no GPU.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../../.." && pwd)
OUT=${1:-"$ROOT/build/tests/shared-contract"}
mkdir -p "$OUT"
cat > "$OUT/NuGet.Config" <<'XML'
<configuration><packageSources><clear /></packageSources></configuration>
XML
dotnet restore "$HERE/SharedContracts.csproj" --configfile "$OUT/NuGet.Config" --artifacts-path "$OUT/art" -p:NuGetAudit=false > "$OUT/build.log" 2>&1
dotnet build "$HERE/SharedContracts.csproj" -c Release --no-restore --artifacts-path "$OUT/art" >> "$OUT/build.log" 2>&1
dotnet "$OUT/art/bin/SharedContracts/release/SharedContracts.dll"
