#!/bin/bash
# 移植质量快检机械部分（合成截图与局目录，不调 AI、不碰游戏数据）
# 门禁覆盖：tools/quality_check.py
set -eu
R=$(cd "$(dirname "$0")/.." && pwd)
PY=${S2A_PYTHON:-${S2A_PY:-$HOME/.s2arm/venv/bin/python3}}; [ -x "$PY" ] || PY=python3
exec "$PY" "$R/tests/quality_check_test.py" "$@"
