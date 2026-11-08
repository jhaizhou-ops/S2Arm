#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 门禁覆盖：compat/tree/src/Ryujinx.HLE/HOS/Services/Ssl/SslService/SslManagedSocketConnection.cs tests/ssl_handshake/ tests/ssl_handshake_test.sh
# 门禁输入：compat/tree/src/ compat/tree/Directory.Build.props compat/tree/Directory.Packages.props
# Fresh machine preparation (explicit network-enabled step, outside this test):
# dotnet restore tests/ssl_handshake/SslHandshakeTest.csproj -m:1 --configfile compat/tree/nuget.config
# The test itself restores only from the normal NuGet cache and repository packages; no downloads.
# Run an explicit serial build, then that exact DLL. Never run a stale binary after a failed build.
set -euo pipefail
H=$(cd "$(dirname "$0")/.." && pwd)
P="$H/tests/ssl_handshake/SslHandshakeTest.csproj"
export MSBUILDDISABLENODEREUSE=1
dotnet restore "$P" -m:1 --configfile "$H/tests/ssl_handshake/nuget.config" -p:NuGetAudit=false --nologo
dotnet build "$P" -c Release -m:1 --no-restore --nologo
exec dotnet "$H/tests/ssl_handshake/bin/Release/net10.0/SslHandshakeTest.dll" "$@"
