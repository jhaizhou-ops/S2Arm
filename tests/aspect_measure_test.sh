#!/bin/bash
# 只读拉伸量具：生成图片、独立几何真值、真实 CLI（不含游戏 / 真机证据）。
# 门禁覆盖：tools/aspect_measure.py tests/aspect_measure_test.py
set -eu
H=$(cd "$(dirname "$0")/.." && pwd)
PY=${S2A_PY:-python3}
export ASPECT_MEASURE=${ASPECT_MEASURE:-$H/tools/aspect_measure.py}
exec "$PY" "$H/tests/aspect_measure_test.py" "$@"
