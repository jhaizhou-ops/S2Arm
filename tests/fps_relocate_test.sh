#!/bin/bash
# 门禁覆盖：tools/fps_relocate.py tests/fps_relocate_test.py
# 帧率表跨版本带用单测（合成两版镜像，约 1 秒）：bash tests/fps_relocate_test.sh
set -u
H=$(cd "$(dirname "$0")/.." && pwd)
PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}; [ -x "$PY" ] || PY=$(command -v python3)
PYTHONDONTWRITEBYTECODE=1 "$PY" "$H/tests/fps_relocate_test.py"
