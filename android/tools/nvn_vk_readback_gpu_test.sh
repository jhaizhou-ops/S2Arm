#!/usr/bin/env bash
# NVN ReadTexels GPU 图像路径的宿主回归：在 CPU Vulkan 参考实现（Mesa lavapipe）上真的建图像、
# 按区域拷回、逐字节比对；并验证“图像存储格式与 NVN 格式不同必须失败”。
#
# 只编生产实现：nvn_vk_readback_gpu.c + nvn_vk_readback_plan.c + nvn_vk_format.c + vk_device.c。
# 缺 lavapipe 时退 2（红，不静默跳过）：这条路径的“区域/子资源/layer 映射”必须在真实
# Vulkan 实现上验一遍，不能只在纯函数层换算过就算。
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
android="$repo/android"
find_icd() {
    if [ -n "${S2A_LAVAPIPE_ICD:-}" ]; then printf '%s\n' "$S2A_LAVAPIPE_ICD"; return; fi
    for f in "$HOME/.local/share/vulkan/icd.d/lvp_icd.json" "$HOME/.local/share/vulkan/icd.d/lvp_icd."*.json \
             /usr/share/vulkan/icd.d/lvp_icd.json /usr/share/vulkan/icd.d/lvp_icd.*.json; do
        [ -f "$f" ] && { printf '%s\n' "$f"; return; }
    done
}
icd=$(find_icd || true)
if [ -z "$icd" ]; then
    echo "【红】找不到 lavapipe ICD：本用例要求 CPU Vulkan 参考实现，不静默跳过。" >&2
    exit 2
fi
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cc_bin="${CC:-cc}"
inc=(-I "$android/native" -I "$android/native/direct" -I "$android/native/nvn"
     -I "$android/tests/vkhost" -I "$android/tests/hostvk"
     -I "$repo/graphics/nvn/third_party/vulkan-headers/include"
     -I "$repo/graphics/nvn/gfx/nvn" -I "$repo/graphics/nvn/gfx/nvn/include" -I "$repo/graphics/nvn"
     -I "$repo/graphics/nvn/gfx/tex" -I "$repo/runtime/include")
"$cc_bin" -std=gnu11 -O1 -g -Wall -Wextra -Werror -Wno-unused-parameter \
  "${inc[@]}" \
  -o "$tmp/nvn_vk_readback_gpu_test" \
  "$android/tests/nvn_vk_readback_gpu_test.c" \
  "$android/native/nvn/nvn_vk_readback_gpu.c" \
  "$android/native/nvn/nvn_vk_readback_plan.c" \
  "$android/native/nvn/nvn_vk_format.c" \
  "$android/native/direct/vk_device.c" \
  -lvulkan -lm -pthread
export VK_DRIVER_FILES=$icd
echo "lavapipe: $icd"
"$tmp/nvn_vk_readback_gpu_test"
echo "nvn-vk-readback-gpu: 全部用例通过"
