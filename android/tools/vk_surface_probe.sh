#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
. "$(dirname "$0")/ndk_toolchain.sh"
ndk=$(s2a_ndk_resolve) || { echo "no NDK; surface probe NOT RUN" >&2; exit 2; }
serial=${S2A_ADB:-$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')}
[ -n "$serial" ] || { echo "no adb device; probe NOT RUN" >&2; exit 2; }
cc=$(s2a_ndk_clang "$ndk" 29) || { echo "no NDK clang; probe NOT RUN" >&2; exit 2; }
out=$(mktemp -d "${TMPDIR:-/tmp}/s2a-vk-surface.XXXXXX")
trap 'rm -rf "$out"' EXIT
"$cc" -std=c11 -O2 -Wall -Wextra -Werror -Wno-missing-field-initializers -I "$repo/android/native/direct" \
    -o "$out/t" "$repo/android/tests/vk_surface_probe.c" \
    "$repo/android/native/direct/vk_device.c" -lvulkan -llog -lm
adb -s "$serial" push "$out/t" /data/local/tmp/t >/dev/null
adb -s "$serial" shell chmod 755 /data/local/tmp/t
adb -s "$serial" shell /data/local/tmp/t
