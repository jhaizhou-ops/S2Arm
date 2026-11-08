#!/bin/bash
# 门禁覆盖：graphics/tools/direct/dsh/*.cs graphics/tools/direct/tests/dsh_cmp/* graphics/tools/direct/tests/dshfn.py
# 遍内自采样改片上读取的离线两半：S2A.Dsh DshFetch 投影屏幕坐标采样识别、DshCompiler.ScrUvLocns（10-30 帧率能耗线；经 dsh_cmp --fn 调）
set -eu
H=$(cd "$(dirname "$0")/.." && pwd)
PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}
PYTHONDONTWRITEBYTECODE=1 "$PY" "$H/tests/screen_uv_test.py"
