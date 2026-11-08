#!/usr/bin/env bash
# NVN ReadTexels 几何/打包换算的宿主单测（纯逻辑，无 Vulkan / 无真机）。
#
# 只编生产实现 nvn_vk_readback_plan.c 与测试本体：这一份换算同时被真机读回路径
# （guest 内存 deswizzle 路径与 GPU 图像路径）使用，宿主测试直接覆盖同一份代码。
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
android="$repo/android"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cc_bin="${CC:-cc}"
"$cc_bin" -std=gnu11 -O1 -Wall -Wextra -Werror \
  -I "$android/native/nvn" \
  -o "$tmp/nvn_vk_readback_plan_test" \
  "$android/tests/nvn_vk_readback_plan_test.c" \
  "$android/native/nvn/nvn_vk_readback_plan.c"
"$tmp/nvn_vk_readback_plan_test"
echo "nvn-vk-readback-plan: 全部用例通过"
