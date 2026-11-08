#!/bin/bash
# 门禁覆盖：tools/sdk_mem_loc.py tools/arm64_aspect_locator.py tests/sdk_mem_loc_test.py
set -eu
H=$(cd "$(dirname "$0")/.." && pwd)
PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}
PYTHONDONTWRITEBYTECODE=1 "$PY" "$H/tests/sdk_mem_loc_test.py"
