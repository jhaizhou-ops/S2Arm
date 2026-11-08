#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 门禁只看：graphics/tools/direct/dsh/* graphics/tools/direct/tests/t_stage_ssbo.py graphics/tools/direct/tests/dsh_cmp/*
set -eu
R=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/stage_ssbo.XXXXXX")
trap 'rm -rf "$T"' EXIT
DN=${DOTNET:-dotnet}
# Tests use restored packages only; an empty local feed prevents network access.
mkdir "$T/feed"
"$DN" restore "$R/graphics/tools/direct/tests/dsh_cmp/dsh_cmp.csproj" --artifacts-path "$T/artifacts" --source "$T/feed" -p:NuGetAudit=false > "$T/build.log" 2>&1 || { cat "$T/build.log"; exit 1; }
"$DN" build "$R/graphics/tools/direct/tests/dsh_cmp/dsh_cmp.csproj" -c Release --no-restore --artifacts-path "$T/artifacts" -o "$T/bin" -p:UseSharedCompilation=false >> "$T/build.log" 2>&1 || { cat "$T/build.log"; exit 1; }
DOTNET="$DN" "${S2A_PY:-python3}" "$R/graphics/tools/direct/tests/t_stage_ssbo.py" "$T/bin/dsh_cmp.dll"
