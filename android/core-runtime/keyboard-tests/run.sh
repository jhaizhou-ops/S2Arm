#!/usr/bin/env bash
# 门禁覆盖：android/core-runtime/AndroidKeyboard.cs android/core-runtime/AndroidHostApi.cs
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE=1
# This source-only project has no package dependencies. Never consult network
# feeds; keep restore and build outputs private to this invocation.
printf '%s\n' '<configuration><packageSources><clear /></packageSources></configuration>' > "$tmp/nuget.config"
dotnet restore "$here/Keyboard.Tests.csproj" --configfile "$tmp/nuget.config" \
    --artifacts-path "$tmp/artifacts" -p:NuGetAudit=false --verbosity quiet
dotnet build "$here/Keyboard.Tests.csproj" --no-restore --disable-build-servers \
    --artifacts-path "$tmp/artifacts" --verbosity quiet
dotnet "$tmp/artifacts/bin/Keyboard.Tests/debug/Keyboard.Tests.dll"
