#!/usr/bin/env bash
# 门禁覆盖：compat/tree/src/Ryujinx.HLE/HOS/Services/Account/ tests/account_offline/ tests/account_offline_test.sh
# Production account command handlers and async execution with a synthetic host transport/kernel event.
set -euo pipefail
H=$(cd "$(dirname "$0")/.." && pwd)
P="$H/tests/account_offline/AccountOffline.csproj"
export MSBUILDDISABLENODEREUSE=1
dotnet restore "$P" -m:1 --configfile "$H/tests/account_offline/nuget.config" -p:NuGetAudit=false --nologo
dotnet build "$P" -c Release -m:1 --no-restore --nologo
exec dotnet "$H/tests/account_offline/bin/Release/net10.0/AccountOffline.dll"
