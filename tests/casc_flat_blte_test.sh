#!/bin/bash
# 门禁覆盖：graphics/tools/shbake/casc_flat.py tests/casc_flat_blte_test.py
set -eu
cd "$(dirname "$0")/.."
PY=${S2A_PY:-${PY:-python3}}
PYTHONDONTWRITEBYTECODE=1 "$PY" tests/casc_flat_blte_test.py
