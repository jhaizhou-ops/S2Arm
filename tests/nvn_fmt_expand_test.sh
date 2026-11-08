#!/bin/bash
# 上传展开目标：中立表 ↔ Metal XP ↔ Vulkan 重定向。
# 门禁只看：graphics/nvn/gfx/nvn/nvn_fmt_info.h graphics/nvn/gfx/tex/nvn_fmt_mtl.c android/native/nvn/nvn_vk_format.c graphics/nvn/tests/nvn_fmt_expand_test.py
# 门禁覆盖：graphics/nvn/gfx/nvn/nvn_fmt_info.h graphics/nvn/gfx/tex/nvn_fmt_mtl.c android/native/nvn/nvn_vk_format.c graphics/nvn/tests/nvn_fmt_expand_test.py
set -eu
H=$(cd "$(dirname "$0")/.." && pwd)
python3 "$H/graphics/nvn/tests/nvn_fmt_expand_test.py"
