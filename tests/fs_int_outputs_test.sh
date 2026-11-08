#!/bin/bash
# 门禁覆盖：graphics/tools/direct/dsh/*.cs graphics/tools/direct/tests/dsh_cmp/* graphics/tools/direct/tests/dshfn.py graphics/tools/direct/tests/t_fs_int_outputs.py
# 整数输出入口 main0_u 的 u_mask 只含真装整数的输出（S2A.Dsh DshCompiler.IntOutputs，上游参考实现（MIT）a4d7bb7b；经 dsh_cmp --fn fs_uint 调）
set -eu
H=$(cd "$(dirname "$0")/.." && pwd)
PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}
PYTHONDONTWRITEBYTECODE=1 "$PY" "$H/graphics/tools/direct/tests/t_fs_int_outputs.py"
