#!/bin/bash
# UE3 包块表（translator/shader_split.py ue3_package / ue3_chunk）合成字节单测：假块表不当块表、块头不合法报红不除零、真块表照解
# 门禁覆盖：translator/shader_split.py
set -u; H=$(cd "$(dirname "$0")/.." && pwd)
PY=${S2A_PYTHON:-${S2A_PY:-}}; [ -n "$PY" ] || { [ -x "$HOME/.s2arm/venv/bin/python3" ] && PY=$HOME/.s2arm/venv/bin/python3 || PY=$(command -v python3); }
exec "$PY" "$H/tests/shader_split_ue3_test.py"
