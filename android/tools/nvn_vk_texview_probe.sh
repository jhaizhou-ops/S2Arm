#!/usr/bin/env bash
# F1.1/F1.2 真机 GPU 微例：采样 view 的通道映射、view 在途引用与 LRU。
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
. "$(dirname "$0")/ndk_toolchain.sh"
ndk=$(s2a_ndk_resolve) || { echo "no NDK; texview probe NOT RUN" >&2; exit 2; }
serial=${S2A_ADB:-$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')}
[ -n "$serial" ] || { echo "no adb device; texview probe NOT RUN" >&2; exit 2; }
cc=$(s2a_ndk_clang "$ndk" 29) || { echo "no NDK clang; probe NOT RUN" >&2; exit 2; }
glslc=$(s2a_ndk_glslc "$ndk" || true)
[ -n "$glslc" ] && [ -x "$glslc" ] || { echo "no glslc; texview probe NOT RUN" >&2; exit 2; }
out=$(mktemp -d "${TMPDIR:-/tmp}/s2a-nvn-vk-texview.XXXXXX")
trap 'adb -s "$serial" shell setprop debug.s2a.view_max 0 >/dev/null 2>&1 || true; rm -rf "$out"' EXIT
mkdir -p "$out/shaders"
"$glslc" --target-env=vulkan1.1 "$repo/android/tests/shaders/direct/view.vert" -o "$out/shaders/view.vert.spv"
"$glslc" --target-env=vulkan1.1 "$repo/android/tests/shaders/direct/view.frag" -o "$out/shaders/view.frag.spv"
"$cc" -std=c11 -O2 -Wall -Wextra -Werror -Wno-missing-field-initializers -Wno-nonnull \
    -I "$repo/android/native/direct" -I "$repo/android/native/nvn" \
    -I "$repo/graphics/nvn/gfx/nvn" -I "$repo/graphics/nvn/gfx/nvn/include" -I "$repo/graphics/nvn/gfx/tex" \
    -o "$out/t" "$repo/android/tests/nvn_vk_texview_test.c" \
    "$repo/android/native/nvn/nvn_vk_texcache.c" "$repo/android/native/nvn/nvn_vk_bcdec.c" "$repo/android/native/nvn/nvn_vk_format.c" \
    "$repo/graphics/nvn/gfx/nvn/nvn_tex.c" "$repo/graphics/nvn/gfx/tex/nvn_deswizzle.c" \
    "$repo/android/native/direct/vk_device.c" -lvulkan -llog -lm
adb -s "$serial" push "$out/t" /data/local/tmp/texview_test >/dev/null
adb -s "$serial" push "$out/shaders" /data/local/tmp/texview-shaders >/dev/null
adb -s "$serial" shell chmod 755 /data/local/tmp/texview_test
adb -s "$serial" shell setprop debug.s2a.view_max 3
adb -s "$serial" shell /data/local/tmp/texview_test /data/local/tmp/texview-shaders
