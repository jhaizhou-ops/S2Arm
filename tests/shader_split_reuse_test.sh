#!/bin/bash
# 离线门禁：真实自编 NSO，调用 translator/shader_split.py；不需要私有输入。
set -euo pipefail
cd "$(dirname "$0")/.."
PY=${S2A_PYTHON:-${S2A_PY:-}}; [ -n "$PY" ] || { [ -x "$HOME/.s2arm/venv/bin/python3" ] && PY=$HOME/.s2arm/venv/bin/python3 || PY=$(command -v python3); }
"$PY" tests/shader_split_reuse.py "${1:-$PWD/translator/shader_split.py}"
