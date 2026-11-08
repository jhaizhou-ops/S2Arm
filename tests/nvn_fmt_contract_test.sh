#!/bin/bash
# 两端 NVN→Vulkan 格式契约：nvn.h 的格式名 vs Android nvn_vk_format.c 的映射。
# 门禁只看：graphics/nvn/gfx/nvn/include/nvn.h android/native/nvn/nvn_vk_format.c graphics/nvn/tests/nvn_fmt_contract_test.py
# 门禁覆盖：graphics/nvn/gfx/nvn/include/nvn.h android/native/nvn/nvn_vk_format.c graphics/nvn/tests/nvn_fmt_contract_test.py
set -eu
H=$(cd "$(dirname "$0")/.." && pwd)
python3 "$H/graphics/nvn/tests/nvn_fmt_contract_test.py"
