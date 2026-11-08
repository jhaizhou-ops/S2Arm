#!/bin/bash
# 门禁覆盖：tools/input_caps_scan.py tests/input_caps_scan_test.py
# 合成输入摘要与T79 JSON；不启动设备、不将夹具作为真实能力证据。
set -eu
H=$(cd "$(dirname "$0")/.." && pwd)
PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}; [ -x "$PY" ] || PY=python3
PYTHONDONTWRITEBYTECODE=1 "$PY" "$H/tests/input_caps_scan_test.py"
