#!/usr/bin/env bash
# 批 A（内容版本与 CPU/GPU 交接）宿主回归：在 CPU Vulkan 参考实现（Mesa lavapipe）上真的建图像、
# 真的清/拷/读，验三条反例（修前红）：① GPU 清红 → CPU 整图写蓝 ② GPU 清红 → CPU 局部写蓝
# ③ 内容 7 → Draw A → 内容 11 → Draw B；另验子资源状态、读回不写回 guest、账本不可用 fail-closed、
# 1 MiB 保护块不是写粒度。
#
# 只编生产实现：nvn_vk_texcache.c + nvn_vk_readback.c + nvn_vk_readback_gpu.c + nvn_vk_readback_plan.c +
# nvn_vk_bcdec.c + nvn_vk_format.c + nvn_tex.c + nvn_dirty.c + nvn_deswizzle.c + vk_device.c。
# 缺 lavapipe 时退 2（红，不静默跳过）：内容交接必须在真实 Vulkan 实现上验字节，不能只做纯逻辑对拍。
#
# 真机（Adreno）验收不在本脚本：设备窗口需排队，见任务报告「需要真机窗口」。
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
     -I "$repo/graphics/nvn/gfx/tex" -I "$repo/runtime/include" -I "$repo/runtime/src")
"$cc_bin" -std=gnu11 -O1 -g -Wall -Wextra -Wno-unused-parameter -Wno-missing-field-initializers \
  "${inc[@]}" \
  -o "$tmp/nvn_vk_texcache_content_test" \
  "$android/tests/nvn_vk_texcache_content_test.c" \
  "$android/native/nvn/nvn_vk_texcache.c" \
  "$android/native/nvn/nvn_vk_readback.c" \
  "$android/native/nvn/nvn_vk_readback_gpu.c" \
  "$android/native/nvn/nvn_vk_readback_plan.c" \
  "$android/native/nvn/nvn_vk_bcdec.c" \
  "$android/native/nvn/nvn_vk_format.c" \
  "$repo/graphics/nvn/gfx/nvn/nvn_tex.c" \
  "$repo/graphics/nvn/gfx/nvn/nvn_dirty.c" \
  "$repo/graphics/nvn/gfx/tex/nvn_deswizzle.c" \
  "$android/native/direct/vk_device.c" \
  -lvulkan -lm -pthread
export VK_DRIVER_FILES=$icd
echo "lavapipe: $icd"
"$tmp/nvn_vk_texcache_content_test"
echo "nvn-vk-texcache-content: 全部用例通过"
