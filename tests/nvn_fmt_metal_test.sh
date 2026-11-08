#!/bin/bash
# 中立格式表 vs Metal 映射（nvn_fmt_mtl.c 是纯 C 表，可在 Linux 检查）。
# 门禁只看：graphics/nvn/gfx/nvn/nvn_fmt_info.h graphics/nvn/gfx/tex/nvn_fmt_mtl.c graphics/nvn/tests/nvn_fmt_metal_test.py
# 门禁覆盖：graphics/nvn/gfx/nvn/nvn_fmt_info.h graphics/nvn/gfx/tex/nvn_fmt_mtl.c graphics/nvn/tests/nvn_fmt_metal_test.py
set -eu
H=$(cd "$(dirname "$0")/.." && pwd)
python3 "$H/graphics/nvn/tests/nvn_fmt_metal_test.py"
