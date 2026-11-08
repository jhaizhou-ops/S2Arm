#!/usr/bin/env bash
# BC/块压缩纹理作为渲染目标（“块=像素”影子）字节级往返：宿主回归（真 Vulkan / Mesa lavapipe）。
#
# 只编生产实现：nvn_vk_mrt.c（nvn_vk_bcrt_* 判定 / 四个拷贝区域）+ nvn_vk_format.c + vk_device.c。
# 用例覆盖：A 纯判定（BC4/BC3 覆盖、拒绝原因、3D 用 imageOffset.z、2D 数组用 baseArrayLayer、
# 影子 bw×bh 紧打包）、B 真 Vulkan 字节往返（3D 深度切片、2D 数组 mip、影子直写）、C 失败路径 +
# 影子尺寸向上取整。修前/改坏必红。
# 缺 lavapipe 时退 2（红，不静默跳过）：块=像素影子必须在真实 Vulkan 上验字节，不能只做纯逻辑对拍。
#
# 真机（Adreno）验收用同源 tools/nvn_vk_bcrt_probe.sh（A 级，同一份用例源码）。
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
if [ -z "$icd" ] || [ ! -f "$icd" ]; then
    echo "【红】找不到 lavapipe ICD（${icd:-空}）：本用例要求 CPU Vulkan 参考实现，不静默跳过。" >&2
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
  -o "$tmp/nvn_vk_bcrt_test" \
  "$android/tests/nvn_vk_bcrt_test.c" \
  "$android/native/nvn/nvn_vk_mrt.c" \
  "$android/native/nvn/nvn_vk_format.c" \
  "$android/native/direct/vk_device.c" \
  -lvulkan -lm -pthread
export VK_DRIVER_FILES="$icd"
echo "lavapipe: $icd"
"$tmp/nvn_vk_bcrt_test"
echo "nvn-vk-bcrt: 全部用例通过（S 级：lavapipe）"
