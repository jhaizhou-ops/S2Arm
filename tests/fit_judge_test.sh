#!/bin/bash
# 门禁覆盖：graphics/metal/fit_judge.h tests/fit_judge_test.c tests/fit_judge_test.py
# 宿主上屏满屏判据单测（合成正反例 + 本机有就跑真截图正反对照；要 clang、NumPy、Pillow）：bash tests/fit_judge_test.sh
set -u
H=$(cd "$(dirname "$0")/.." && pwd)
PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}; [ -x "$PY" ] || PY=$(command -v python3)
"$PY" -c "import numpy, PIL" 2> /dev/null || { echo "🔴 缺 numpy / Pillow：$PY"; exit 2; }
command -v clang > /dev/null || { echo "🔴 缺 clang"; exit 2; }
PYTHONDONTWRITEBYTECODE=1 "$PY" "$H/tests/fit_judge_test.py"
