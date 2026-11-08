#!/bin/bash
# Production IR/Analyze/reflection and Metal compilation; never executes GPU work.
# 门禁覆盖：graphics/tools/direct/dsh/Dsh.cs translator/dmsh_xlate/Program.cs tests/direct_resolution_assets/*
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
dotnet build "$ROOT/tests/direct_resolution_assets/DirectResolutionAssets.csproj" -c Release \
  --artifacts-path "$OUT/dotnet" -o "$OUT/tool" -p:NuGetAudit=false -p:UseSharedCompilation=false -m:2 -v minimal
dotnet "$OUT/tool/dsh_cmp.dll" "$OUT/assets"
