#!/bin/bash
# 门禁覆盖：graphics/tools/direct/dsh/*.cs graphics/tools/direct/tests/dsh_cmp/* graphics/tools/direct/tests/dshfn.py graphics/tools/direct/tests/t_first_store.py
# 只有派发里第一个调用做的存储挪给宿主（S2A.Dsh DshCompiler.FirstStore，上游参考实现（MIT）c8521eeb + e07cba1c；经 dsh_cmp --fn first_store 调）
set -eu
H=$(cd "$(dirname "$0")/.." && pwd)
PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}
PYTHONDONTWRITEBYTECODE=1 "$PY" "$H/graphics/tools/direct/tests/t_first_store.py"
