#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
. "$(dirname "$0")/ndk_toolchain.sh"
ndk=$(s2a_ndk_resolve) || { echo "no NDK; surface-select probe NOT RUN" >&2; exit 2; }
serial=${S2A_ADB:-$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')}
[ -n "$serial" ] || { echo "no adb device; probe NOT RUN" >&2; exit 2; }
cc=$(s2a_ndk_clang "$ndk" 29) || { echo "no NDK clang; probe NOT RUN" >&2; exit 2; }
out=$(mktemp -d "${TMPDIR:-/tmp}/s2a-nvn-vk-surface2.XXXXXX")
trap 'rm -rf "$out"' EXIT
"$cc" -std=c11 -O2 -Wall -Wextra -Werror -I "$repo/android/native/nvn" \
    -o "$out/t" "$repo/android/tests/nvn_vk_surface_test.c" \
    "$repo/android/native/nvn/nvn_vk_surface.c" -lvulkan
adb -s "$serial" push "$out/t" /data/local/tmp/t >/dev/null
adb -s "$serial" shell chmod 755 /data/local/tmp/t
adb -s "$serial" shell /data/local/tmp/t
