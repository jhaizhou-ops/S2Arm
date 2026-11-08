#!/usr/bin/env bash
# 纹理缓存语义自测（真机）：同身份复用 / 同址新 serial 重建 / 未知格式拒绝。
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
. "$(dirname "$0")/ndk_toolchain.sh"
ndk=$(s2a_ndk_resolve) || { echo "no NDK; texcache probe NOT RUN" >&2; exit 2; }
serial=${S2A_ADB:-$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')}
[ -n "$serial" ] || { echo "no adb device; texcache probe NOT RUN" >&2; exit 2; }
cc=$(s2a_ndk_clang "$ndk" 29) || { echo "no NDK clang; texcache probe NOT RUN" >&2; exit 2; }
out=$(mktemp -d "${TMPDIR:-/tmp}/s2a-nvn-vk-texcache.XXXXXX")
trap 'rm -rf "$out"' EXIT
"$cc" -std=c11 -O2 -Wall -Wextra -Werror -Wno-missing-field-initializers -Wno-nonnull \
    -I "$repo/android/native/nvn/compat" -I "$repo" -I "$repo/runtime/include" -I "$repo/runtime/src" -I "$repo/graphics/track" -I "$repo/graphics/nvn/host" \
    -I "$repo/android/native/direct" -I "$repo/android/native/nvn" -I "$repo/graphics/nvn/gfx/nvn" -I "$repo/graphics/nvn/gfx/nvn/include" -I "$repo/graphics/nvn/gfx/tex" \
    -o "$out/nvn_vk_texcache_test" "$repo/android/tests/nvn_vk_texcache_test.c" "$repo/android/tests/nvn_probe_track_stubs.c" \
    "$repo/android/native/nvn/nvn_vk_texcache.c" "$repo/android/native/nvn/nvn_vk_bcdec.c" "$repo/android/native/nvn/nvn_vk_format.c" "$repo/graphics/nvn/gfx/nvn/nvn_tex.c" "$repo/graphics/nvn/gfx/tex/nvn_deswizzle.c" \
    "$repo/graphics/nvn/gfx/nvn/nvn_dirty.c" "$repo/android/native/nvn/nvn_host_hooks.c" "$repo/runtime/src/direct_host.c" \
    "$repo/android/native/direct/vk_device.c" -lvulkan -llog -lm
adb -s "$serial" push "$out/nvn_vk_texcache_test" /data/local/tmp/ >/dev/null
adb -s "$serial" shell chmod 755 /data/local/tmp/nvn_vk_texcache_test
adb -s "$serial" shell /data/local/tmp/nvn_vk_texcache_test
