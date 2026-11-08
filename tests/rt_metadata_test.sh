#!/bin/bash
# R3 社区元数据三表交换；纯合成、离线，不运行 Metal / 游戏 / 设备。
# 门禁覆盖：graphics/tools/direct/rt_metadata.py graphics/tools/direct/tests/t_rt_metadata.py graphics/tools/direct/rt_collect.py
set -eu
H=$(cd "$(dirname "$0")/.." && pwd)
PY=${S2A_PY:-python3}
PYTHONDONTWRITEBYTECODE=1 "$PY" "$H/graphics/tools/direct/tests/t_rt_metadata.py"
