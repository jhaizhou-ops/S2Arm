#!/usr/bin/env bash
# NVN 采样器 → VkSamplerCreateInfo 映射自测（真机）。
#   一、nvn_vk_sampler_test.c：真实 VkDevice 上建采样器（过滤 / 寻址 / 比较 / 未知枚举拒绝）。
#   二、nvn_vk_sampler_mapping_test.c：P0-2 映射判定表（精确 / 经验证的等价 / 准确拒绝），
#       纯映射不建设备，所以宿主与真机跑同一份用例。
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
. "$(dirname "$0")/ndk_toolchain.sh"
ndk=$(s2a_ndk_resolve) || { echo "no NDK; sampler probe NOT RUN" >&2; exit 2; }
serial=${S2A_ADB:-$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')}
[ -n "$serial" ] || { echo "no adb device; sampler probe NOT RUN" >&2; exit 2; }
cc=$(s2a_ndk_clang "$ndk" 29) || { echo "no NDK clang; sampler probe NOT RUN" >&2; exit 2; }
out=$(mktemp -d "${TMPDIR:-/tmp}/s2a-nvn-vk-sampler.XXXXXX")
trap 'rm -rf "$out"' EXIT
"$cc" -std=c11 -O2 -Wall -Wextra -Werror -I "$repo/android/native/nvn" -I "$repo/graphics/nvn/gfx/nvn" -I "$repo/graphics/nvn/gfx/nvn/include" \
    -o "$out/nvn_vk_sampler_test" "$repo/android/tests/nvn_vk_sampler_test.c" \
    "$repo/android/native/nvn/nvn_vk_sampler.c" -lvulkan
# 映射判定表：真机上 __system_property_get 由 libc 提供，关掉测试里的宿主桩。
"$cc" -std=c11 -O2 -Wall -Wextra -Werror -DSAMPLER_TEST_NO_PROP_STUB \
    -DSAMPLER_SOURCE="\"$repo/android/native/nvn/nvn_vk_sampler.c\"" \
    -I "$repo/android/native/nvn" -I "$repo/graphics/nvn/gfx/nvn" -I "$repo/graphics/nvn/gfx/nvn/include" \
    -o "$out/nvn_vk_sampler_mapping_test" "$repo/android/tests/nvn_vk_sampler_mapping_test.c" -lvulkan
for t in nvn_vk_sampler_test nvn_vk_sampler_mapping_test; do
    adb -s "$serial" push "$out/$t" /data/local/tmp/ >/dev/null
    adb -s "$serial" shell chmod 755 "/data/local/tmp/$t"
done
adb -s "$serial" shell /data/local/tmp/nvn_vk_sampler_test
adb -s "$serial" shell /data/local/tmp/nvn_vk_sampler_mapping_test
