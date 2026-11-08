#!/bin/bash
# 通用帧率表（UE4 控制台变量按名定位）单测：假引擎判断与定位，不读游戏数据
# 门禁覆盖：tools/fps_generic.py
set -eu
R=$(cd "$(dirname "$0")/.." && pwd)
exec "${S2A_PY:-python3}" "$R/tests/fps_generic_test.py" "$@"
