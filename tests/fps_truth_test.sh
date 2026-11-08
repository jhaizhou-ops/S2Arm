#!/bin/bash
# 门禁覆盖：tools/fps_truth.py tests/fps_truth_test.py
# 纯合成日志、手算中位/边界；写表只用临时目录，不是游戏帧率实测。
set -eu
H=$(cd "$(dirname "$0")/.." && pwd)
PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}; [ -x "$PY" ] || PY=python3
PYTHONDONTWRITEBYTECODE=1 "$PY" "$H/tests/fps_truth_test.py"
