#!/usr/bin/env bash
# 门禁手动：只能 Linux（托管原生互操作，非 Linux 退 75）；门禁 Linux 路径本轮没实跑验证
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# Linux-only manual entry: see managed/SaveCommit.ManagedTests.csproj declaration; no gate.
# Linux CPU-only adapter interop; not Android device or game acceptance.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
if [ "$(uname -s)" != Linux ]; then
    echo 'ENV_NOT_READY: managed native interop requires Linux' >&2; exit 75
fi
DOTNET=${DOTNET:-dotnet}
OUT=$(mktemp -d "${TMPDIR:-/tmp}/s2a-managed-save-XXXXXX")
trap 'rm -rf "$OUT"' EXIT
PROJECT=$HERE/managed/SaveCommit.ManagedTests.csproj
"${CC:-cc}" -std=c11 -O2 -g -Wall -Wextra -Werror -Wpedantic -fPIC -shared \
    "$HERE/../../../native/s2a_savecommit.c" -o "$OUT/libs2a_native.so"
# No package sources or downloads; this project compiles the actual upstream seam.
"$DOTNET" build "$PROJECT" --nologo --configfile "$HERE/managed/NuGet.Config" \
    -p:BaseIntermediateOutputPath="$OUT/obj/" -o "$OUT/positive"
timeout 30s "$DOTNET" "$OUT/positive/SaveCommit.ManagedTests.dll" "$OUT/libs2a_native.so"
timeout 30s "$DOTNET" "$OUT/positive/SaveCommit.ManagedTests.dll" --missing-binding
# Remove only the real module initializer: the test must fail, not silently use
# an adapter the test installed itself. Keep production files untouched.
"$DOTNET" build "$PROJECT" --nologo --no-restore \
    -p:BaseIntermediateOutputPath="$OUT/obj/" -p:OmitSaveCommitRegistration=true -o "$OUT/negative"
set +e
timeout 30s "$DOTNET" "$OUT/negative/SaveCommit.ManagedTests.dll" --missing-binding > "$OUT/negative.log" 2>&1
rc=$?
set -e
cat "$OUT/negative.log"
if [ "$rc" = 0 ] || [ "$rc" = 124 ] || ! grep -q 'actual Android AOT module initializer did not register adapter' "$OUT/negative.log"; then
    echo 'FAIL: missing-registration negative control was ineffective' >&2; exit 1
fi
echo 'PASS actual-contract adapter interop, missing binding, and startup-registration negative control'
