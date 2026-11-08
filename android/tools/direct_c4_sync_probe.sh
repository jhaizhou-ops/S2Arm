#!/usr/bin/env bash
# C4：真机 fence 完成/超时探针。present fence/WSI 退休尚未接入，本脚本不声称 scanout 通过。
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
. "$(dirname "$0")/ndk_toolchain.sh"
ndk=$(s2a_ndk_resolve) || { echo "no NDK; C4 probe NOT RUN" >&2; exit 2; }
serial=${S2A_ADB:-$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')}
[ -n "$serial" ] || { echo "no adb device; C4 probe NOT RUN" >&2; exit 2; }
out=$(mktemp -d "${TMPDIR:-/tmp}/s2a-vk-sync.XXXXXX")
trap 'rm -rf "$out"' EXIT
cc=$(s2a_ndk_clang "$ndk" 29) || { echo "no NDK clang for this host; probe NOT RUN" >&2; exit 2; }
"$cc" -std=c11 -O2 -Wall -Wextra -Werror -I "$repo/android/native/direct" \
    -o "$out/vk_sync" "$repo/android/tests/vk_sync_test.c" \
    "$repo/android/native/direct/vk_sync.c" "$repo/android/native/direct/vk_device.c" \
    -lvulkan -llog -lm
"$cc" -std=c11 -O2 -Wall -Wextra -Werror -I "$repo/android/native/direct" \
    -o "$out/vk_track" "$repo/android/tests/vk_track_test.c" \
    "$repo/android/native/direct/vk_track.c" "$repo/android/native/direct/vk_device.c" \
    -lvulkan -llog -lm -pthread
adb -s "$serial" push "$out/vk_sync" /data/local/tmp/s2a-vk-micro/vk_sync >/dev/null
adb -s "$serial" push "$out/vk_track" /data/local/tmp/s2a-vk-micro/vk_track >/dev/null
adb -s "$serial" shell chmod 755 /data/local/tmp/s2a-vk-micro/vk_sync /data/local/tmp/s2a-vk-micro/vk_track
adb -s "$serial" shell /data/local/tmp/s2a-vk-micro/vk_sync
adb -s "$serial" shell /data/local/tmp/s2a-vk-micro/vk_track
