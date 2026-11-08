#!/usr/bin/env bash
# NVN → Vulkan 格式映射自测（真机：已知样例 + 未知格式必须 UNDEFINED）。
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
. "$(dirname "$0")/ndk_toolchain.sh"
ndk=$(s2a_ndk_resolve) || { echo "no NDK; format probe NOT RUN" >&2; exit 2; }
serial=${S2A_ADB:-$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')}
[ -n "$serial" ] || { echo "no adb device; format probe NOT RUN" >&2; exit 2; }
cc=$(s2a_ndk_clang "$ndk" 29) || { echo "no NDK clang; format probe NOT RUN" >&2; exit 2; }
out=$(mktemp -d "${TMPDIR:-/tmp}/s2a-nvn-vk-format.XXXXXX")
trap 'rm -rf "$out"' EXIT
"$cc" -std=c11 -O2 -Wall -Wextra -Werror -I "$repo/android/native/nvn" -I "$repo/graphics/nvn/gfx/nvn" \
    -o "$out/nvn_vk_format_test" "$repo/android/tests/nvn_vk_format_test.c" \
    "$repo/android/native/nvn/nvn_vk_format.c" -lvulkan
adb -s "$serial" push "$out/nvn_vk_format_test" /data/local/tmp/ >/dev/null
adb -s "$serial" shell chmod 755 /data/local/tmp/nvn_vk_format_test
adb -s "$serial" shell /data/local/tmp/nvn_vk_format_test
