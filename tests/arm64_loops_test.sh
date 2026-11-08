#!/bin/bash
# 门禁覆盖：tools/arm64_loops.py
# R6: tools/arm64_loops.py CLI/API, original synthetic NSO only.
set -eu
H=$(cd "$(dirname "$0")/.." && pwd)
PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}
PYTHONDONTWRITEBYTECODE=1 "$PY" "$H/tests/arm64_loops_test.py"
