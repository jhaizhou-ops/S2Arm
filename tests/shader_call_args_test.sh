#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 门禁覆盖：compat/tree/src/Ryujinx.Graphics.Shader/StructuredIr/AstOptimizer.cs compat/patches/*call-args-no-propagate.patch
# #1166：真实原创 Maxwell -> SPIR-V -> lavapipe；依赖 #1168 框架及其 C0 输入支持。
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
if [[ ! -f "$ROOT/tests/shader_cases_test.sh" ]]; then
    echo '缺少 #1168 shader_cases_test.sh；Call 参数回归未执行，不能视为通过' >&2
    exit 2
fi
export SHADER_CASES_PROBE_CLAMP=1
exec bash "$ROOT/tests/shader_cases_test.sh"
