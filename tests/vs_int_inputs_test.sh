#!/bin/bash
# 门禁覆盖：graphics/tools/direct/dsh/*.cs graphics/tools/direct/tests/dsh_cmp/* graphics/tools/direct/tests/dshfn.py graphics/tools/direct/tests/t_vs_int_inputs.py tests/ampere_isa/cases.py
# 顶点输入整数推断不随 DebugMode 变（S2A.Dsh DshCompiler.IntInputs）：手写 MSL 两种写法 + 合成 NVN2 顶点着色器整条出包链，期望按规则手推（见 t_vs_int_inputs.py 文件头）
set -eu
H=$(cd "$(dirname "$0")/.." && pwd)
make -s -C "$H/graphics/metal" -j"${S2A_CPU_GATE:-6}" "$H/build/gal/libnxgal.dylib" > /dev/null
PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}
PYTHONDONTWRITEBYTECODE=1 "$PY" "$H/graphics/tools/direct/tests/t_vs_int_inputs.py"
