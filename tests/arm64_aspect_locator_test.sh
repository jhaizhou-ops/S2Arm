#!/bin/bash
# Q4: real tools/arm64_aspect_locator.py CLI/API, synthetic NSO only.
set -eu
H=$(cd "$(dirname "$0")/.." && pwd)
PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}
PYTHONDONTWRITEBYTECODE=1 "$PY" "$H/tests/arm64_aspect_locator_test.py"
