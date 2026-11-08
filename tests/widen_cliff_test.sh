#!/bin/bash
# 宽屏两侧缺渲染判据单测（合成图，不用游戏截图）
# 门禁覆盖：tools/widen_cliff.py
set -eu
R=$(cd "$(dirname "$0")/.." && pwd)
exec "${S2A_PY:-python3}" "$R/tests/widen_cliff_test.py" "$@"
