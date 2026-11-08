#!/bin/bash
# 只读拒收事件汇总：tools/cpatch_rejections.py；手算期望 + 真实 plan/prune 的合成输入。
set -eu
R=$(cd "$(dirname "$0")/.." && pwd)
PY=${S2A_PY:-python3}
exec "$PY" "$R/tests/cpatch_rejections_test.py" "$@"
