#!/bin/bash
# 门禁覆盖：tools/direct_compare/* tests/direct_compare/* tests/direct_compare_test.sh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${DIRECT_COMPARE_TEST_ROOT:-"$ROOT/build/direct_compare_test"}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
export DIRECT_COMPARE_TEST_ROOT="$OUT"
export TMPDIR="$OUT" TMP="$OUT" TEMP="$OUT"
export PYTHONDONTWRITEBYTECODE=1
bash "$ROOT/tools/direct_compare/build_png_metrics.sh" "$OUT/build"
export DIRECT_COMPARE_CODEC="$OUT/build/png-metrics"
python3 "$ROOT/tests/direct_compare/test_compare.py"
