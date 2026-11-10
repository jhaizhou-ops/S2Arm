#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 门禁覆盖：runtime/rewriter/* tests/rewrite_imm7_test.py tests/rewrite_redzone_test.py tests/rewrite_redzone_exec.c
# imm7准入：实际C CLI，合成NSO，手算/独立解码SP有效地址，不改金样。
set -eu
H=$(cd "$(dirname "$0")/.." && pwd)
PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}
REW=${REW:-$("$PY" "$H/pack/rewriter.py" c-path | tail -1)}
[ -x "$REW" ] || { echo '不通 取不到C改写器'; exit 1; }
REW="$REW" "$PY" "$H/tests/rewrite_imm7_test.py"
if [ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ]; then
    REW="$REW" "$PY" "$H/tests/rewrite_redzone_test.py"
fi
