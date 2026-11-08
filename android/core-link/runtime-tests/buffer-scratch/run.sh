#!/usr/bin/env bash
# Build the production CPU-only lease implementation; never fetch dependencies.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
dotnet_bin=${DOTNET:-$(command -v dotnet || true)}
if [ -z "$dotnet_bin" ]; then
    echo '🔴 buffer-scratch: .NET 10 SDK required (set DOTNET or PATH)' >&2
    exit 1
fi
export DOTNET_PROCESSOR_COUNT=${DOTNET_PROCESSOR_COUNT:-2}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/s2a-buffer-scratch.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
printf '%s\n' '<configuration><packageSources><clear /></packageSources></configuration>' > "$tmp/NuGet.Config"
"$dotnet_bin" build "$here/BufferScratch.Tests.csproj" -c Release \
    --configfile "$tmp/NuGet.Config" --artifacts-path "$tmp/artifacts" \
    -p:NuGetAudit=false -v:q
# No native host exports are available here: test the actual managed fallback.
# Each policy is read in a fresh process, before production static initialization.
for policy in 0 1; do
    S2A_BUFFER_READ_SCRATCH=$policy S2A_MO_NATIVE=0 S2A_ALLOC_TRACE=0 \
        "$dotnet_bin" "$tmp/artifacts/bin/BufferScratch.Tests/release/BufferScratch.Tests.dll"
done
echo 'buffer-scratch 期望 两种策略的租借边界全过 → 真结果 通过'
