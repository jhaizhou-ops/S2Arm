#!/bin/bash
# 门禁覆盖：tools/quicktest/rates.py tests/quicktest_rates_test.py
# 手写 TSV 与手算三个率，不起局、不读取实际普查目录。
set -eu
H=$(cd "$(dirname "$0")/.." && pwd)
PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}; [ -x "$PY" ] || PY=python3
# 不读本机真实五问表（packq/autorun/五问.tsv）：census.py sum 会按它数五问全过，手写 TSV 的行没有「键」列，本机有这张表时单测假红（11-01 入队预检撞上）
export S2A_FIVEQ_TSV=/nonexistent/五问.tsv
PYTHONDONTWRITEBYTECODE=1 "$PY" "$H/tests/quicktest_rates_test.py"
