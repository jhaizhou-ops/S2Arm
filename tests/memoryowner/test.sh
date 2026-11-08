#!/bin/bash
set -euo pipefail

MEMORYOWNER_TEST_HERE=$(cd "$(dirname "$0")" && pwd)
MEMORYOWNER_TEST_ROOT=$(cd "$MEMORYOWNER_TEST_HERE/../.." && pwd)
MEMORYOWNER_TEST_OUT=${1:-"$MEMORYOWNER_TEST_ROOT/build/memoryowner"}
MEMORYOWNER_TEST_PROJECT="$MEMORYOWNER_TEST_HERE/MemoryOwner.csproj"

dotnet build "$MEMORYOWNER_TEST_PROJECT" -c Release --artifacts-path "$MEMORYOWNER_TEST_OUT" -v quiet -nologo
dotnet run --project "$MEMORYOWNER_TEST_PROJECT" -c Release --artifacts-path "$MEMORYOWNER_TEST_OUT" --no-build
for memoryowner_test_mode in bounds-byte bounds-ushort oversize accounting skip-accounting; do
    dotnet run --project "$MEMORYOWNER_TEST_PROJECT" -c Release --artifacts-path "$MEMORYOWNER_TEST_OUT" --no-build -- "$memoryowner_test_mode"
done
