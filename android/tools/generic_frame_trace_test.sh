#!/usr/bin/env bash
set -euo pipefail
android=$(cd "$(dirname "$0")/.." && pwd)
out=$(mktemp -d "${S2A_HOST_OUT_ROOT:-${TMPDIR:-/tmp}}/frame-trace.XXXXXXXX")
trap 'rm -rf "$out"' EXIT
"${CC:-cc}" -shared -fPIC "$android/tests/frame-trace-managed/stub.c" -o "$out/libs2a-frame-test.so"
S2A_FRAME_TEST_LIB="$out/libs2a-frame-test.so" "${DOTNET:-dotnet}" run --project "$android/tests/frame-trace-managed/FrameTrace.csproj" --artifacts-path "$out/artifacts"
