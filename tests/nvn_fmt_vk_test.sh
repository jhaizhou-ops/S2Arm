#!/bin/bash
# 中立格式表 vs Android Vulkan 映射（nvn_vk_format.c）。
# 门禁只看：graphics/nvn/gfx/nvn/nvn_fmt_info.h android/native/nvn/nvn_vk_format.c graphics/nvn/tests/nvn_fmt_vk_test.py
# 门禁覆盖：graphics/nvn/gfx/nvn/nvn_fmt_info.h android/native/nvn/nvn_vk_format.c graphics/nvn/tests/nvn_fmt_vk_test.py
set -eu
H=$(cd "$(dirname "$0")/.." && pwd)
python3 "$H/graphics/nvn/tests/nvn_fmt_vk_test.py"
