#!/bin/bash
# Offline only; caller chooses a cache root. No downloads, installs or real AI calls.
set -eu
R=$(cd "$(dirname "$0")/.." && pwd)
O=${1:-${TMPDIR:-/tmp}/widen-judge-tests}
PYTHONDONTWRITEBYTECODE=1 python3 "$R/tests/widen_judge_test.py" "$O"
