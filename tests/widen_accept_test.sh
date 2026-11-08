#!/bin/bash
# 门禁覆盖：tools/widen_accept.py tools/ab_pair.sh tests/widen_accept_test.py
# 满屏任意比例自动验收单测（合成纹理正反例 + 合成 host.log + 临时仓库写表；要 NumPy + Pillow）：bash tests/widen_accept_test.sh
set -u
H=$(cd "$(dirname "$0")/.." && pwd)
PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}; [ -x "$PY" ] || PY=$(command -v python3)
"$PY" -c "import numpy, PIL" 2> /dev/null || { echo "🔴 缺 numpy / Pillow（量具要用）：$PY"; exit 2; }
bash -n "$H/tools/ab_pair.sh" || { echo "🔴 tools/ab_pair.sh 语法错"; exit 1; }
PYTHONDONTWRITEBYTECODE=1 "$PY" "$H/tests/widen_accept_test.py"
