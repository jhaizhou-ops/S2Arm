#!/bin/bash
# D2 纯原因说明；生产合同 pack/cpatch.py，说明实现 graphics/cpatch/reasons.py。
# 门禁覆盖：graphics/cpatch/reasons.py pack/cpatch.py
set -eu
H=$(cd "$(dirname "$0")/.." && pwd)
PY=${S2A_PY:-python3}
"$PY" "$H/tests/cpatch_reasons_test.py"
