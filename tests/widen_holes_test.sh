#!/bin/bash
# 门禁覆盖：tests/visual/widen_holes.py tests/widen_holes_test.py
# 既有 numpy/Pillow；纯合成 f32/json 与隔离阈值负控，不起局。
set -eu
H=$(cd "$(dirname "$0")/.." && pwd)
PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}; [ -x "$PY" ] || PY=python3
PYTHONDONTWRITEBYTECODE=1 "$PY" "$H/tests/widen_holes_test.py"
