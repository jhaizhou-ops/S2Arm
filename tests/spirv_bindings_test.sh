#!/bin/bash
# spirv_msl.fix_bindings：缺 Binding 的描述符变量按 SPIR-V 缺省 0 补修饰、冲突报红（手造字流，不要外部工具）
# 门禁覆盖：graphics/tools/spirv_msl.py tests/spirv_bindings_test.py tests/spirv_bindings_test.sh
set -eu
R=$(cd "$(dirname "$0")/.." && pwd)
exec python3 "$R/tests/spirv_bindings_test.py"
