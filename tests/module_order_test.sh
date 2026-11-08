#!/bin/bash
# 门禁覆盖：tools/module_order.py android/tools/stage_a0.py android/tools/make_pack.py pack/ship_ext.py
# Horizon 装载序单测入口（tests/module_order_test.py）：乱序输入 → 出包端点写 main → subsdk0..N → sdk；负对照 sorted()。
set -u
H=$(cd "$(dirname "$0")/.." && pwd)
PY=${PY:-python3}
"$PY" "$H/tests/module_order_test.py" && echo "module_order 自测 通过" || { echo "module_order 自测 失败"; exit 1; }
