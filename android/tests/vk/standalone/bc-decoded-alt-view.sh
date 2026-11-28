#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 门禁间接：android/tests/vk/run.sh 默认按 standalone/*.sh 通配执行，单跑用 --bc-decoded-alt-view。
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../../.." && pwd)
[ -z "${1:-}" ] || exit 64
: "${S2A_LAVAPIPE_ICD:?lavapipe required}" "${S2A_VK_LAYER_DIR:?validation required}"
[ -f "$repo/build/c883-ndk/vulkan/vulkan_core.h" ] || { echo 'NDK 29 headers missing' >&2; exit 2; }
out="$repo/build/vk-bc-decoded-alt-view"
mkdir -p "$out"
"${GLSLC:-glslc}" --target-env=vulkan1.1 "$repo/android/tests/vk/shaders/samp_at.comp" -o "$out/samp_at.comp.spv"
spirv-val --target-env vulkan1.1 "$out/samp_at.comp.spv"
inc=()
for d in build/c883-ndk android/tests/vkhost graphics/nvn graphics/nvn/replay graphics/nvn/gfx/nvn \
         graphics/nvn/gfx/nvn/include graphics/nvn/gfx/tex android/native android/native/nvn android/native/direct runtime/include; do
    inc+=(-I "$repo/$d")
done
src=("$repo/android/tests/vk/t_bc_decoded_alt_view.c" "$repo/graphics/nvn/replay/nvn_unimpl.c")
for f in android/native/nvn/backend_vulkan.c android/native/nvn/nvn_pipe_flight.c android/native/nvn/nvn_vk_pipe_once.c \
         android/native/direct/vk_device.c android/native/direct/gs_path.c android/native/capprobe/capprobe_host.c \
         android/native/nvn/nvn_vk_format.c graphics/nvn/gfx/nvn/nvn_fmt_expand.c android/native/nvn/nvn_vk_bcdec.c \
         android/native/nvn/nvn_vk_driver_cache.c android/native/direct/sha256.c graphics/nvn/gfx/nvn/nvn_tex.c \
         graphics/nvn/gfx/tex/nvn_deswizzle.c graphics/nvn/gfx/tex/nvn_bcdec.c; do
    src+=("$repo/$f")
done
cc -D_POSIX_C_SOURCE=200809L -std=c11 -O1 -g -Wall -Wextra -Werror -Wno-unused-parameter \
    -ffunction-sections -fdata-sections -DS2A_ANDROID_VK_BACKEND_NVN_VK=1 -DS2A_BCDEC_HOST_TEST \
    "${inc[@]}" "${src[@]}" -Wl,--gc-sections -lvulkan -lpthread -lm -o "$out/test"

export VK_DRIVER_FILES="$S2A_LAVAPIPE_ICD" VK_LAYER_PATH="$S2A_VK_LAYER_DIR"
export VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation
export VK_LAYER_ENABLES=VK_VALIDATION_FEATURE_ENABLE_SYNCHRONIZATION_VALIDATION_EXT
no_validation_errors() {
    grep -q '^device: llvmpipe' "$1" && ! grep -qE 'Validation Error|VUID-|SYNC-HAZARD-' "$1"
}

log="$out/run.log"
rc=0
S2A_VK_BC_DECODE=force timeout 180 "$out/test" "$out" > "$log" 2>&1 || rc=$?
cat "$log"
[ "$rc" = 0 ] && no_validation_errors "$log" && grep -qx 'bc-decoded-alt-view: failures=0' "$log" || exit 1

# 负控：把 UNORM->SRGB 采样改用 UNORM 视图，像素断言必须精准报红（0 校验层错误）
neg="$out/wrong-view.log"
rc=0
S2A_VK_BC_DECODE=force timeout 180 "$out/test" "$out" --wrong-view > "$neg" 2>&1 || rc=$?
if [ "$rc" != 1 ] || ! no_validation_errors "$neg" ||
   ! grep -qx 'bc-decoded-alt-view: failures=1' "$neg" ||
   ! grep -q 'BC1_RGBA_UNORM->SRGB alt sample got=' "$neg"; then
    cat "$neg"; exit 1
fi
echo '【负对照开始】'
grep 'BC1_RGBA_UNORM->SRGB alt sample got=' "$neg"
echo '【负对照结束】'
echo '【绿】BC 解码贴图 UNORM<->SRGB 同族视图采样像素读回、未压缩与不兼容异格式视图拒收全通，Vulkan 校验 0 条'
