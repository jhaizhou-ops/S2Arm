#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 门禁覆盖：compat/tree/src/Ryujinx.HLE/HOS/LibHacHorizonManager.cs tests/libhac_horizon_dispose/* tests/libhac_horizon_dispose_test.sh
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v dotnet >/dev/null 2>&1 || ! dotnet --list-sdks | grep -q '^10\.'; then
    echo "缺少 .NET 10 SDK；未运行 LibHac 释放回归（不自动下载）" >&2
    exit 2
fi
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
P=tests/libhac_horizon_dispose/HorizonDispose.csproj
export MSBUILDDISABLENODEREUSE=1
dotnet restore "$P" --configfile tests/libhac_horizon_dispose/NuGet.Config --artifacts-path "$T" -p:NuGetAudit=false --nologo
dotnet run --project "$P" --no-restore --artifacts-path "$T" --no-launch-profile
