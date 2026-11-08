#!/bin/bash
# 覆盖：tools/community_build_compare.py tests/community_build_compare_test.py
# 只用合成元数据；独立期望、坏格式拒绝与只读边界，不代表补丁兼容或游戏验证。
set -euo pipefail
H=$(cd "$(dirname "$0")/.." && pwd)
PY=${S2A_PY:-python3}
PYTHONDONTWRITEBYTECODE=1 "$PY" "$H/tests/community_build_compare_test.py"
