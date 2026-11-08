#!/usr/bin/env bash
# 宿主钩子接线自测（真机）：dm_* 不再落弱空函数。
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
. "$(dirname "$0")/ndk_toolchain.sh"
ndk=$(s2a_ndk_resolve) || { echo "no NDK; hooks probe NOT RUN" >&2; exit 2; }
serial=${S2A_ADB:-$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')}
[ -n "$serial" ] || { echo "no adb device; hooks probe NOT RUN" >&2; exit 2; }
cc=$(s2a_ndk_clang "$ndk" 29) || { echo "no NDK clang; hooks probe NOT RUN" >&2; exit 2; }
out=$(mktemp -d "${TMPDIR:-/tmp}/s2a-nvn-hooks.XXXXXX")
trap 'rm -rf "$out"' EXIT
"$cc" -std=c11 -O2 -Wall -Wextra -Werror -Wno-missing-field-initializers \
    -I "$repo" -I "$repo/runtime/include" -I "$repo/runtime/src" -I "$repo/graphics/track" -I "$repo/graphics/nvn/host" \
    -o "$out/nvn_host_hooks_test" "$repo/android/tests/nvn_host_hooks_test.c" \
    "$repo/android/native/nvn/nvn_host_hooks.c" "$repo/runtime/src/direct_host.c" -llog
adb -s "$serial" push "$out/nvn_host_hooks_test" /data/local/tmp/ >/dev/null
adb -s "$serial" shell chmod 755 /data/local/tmp/nvn_host_hooks_test
adb -s "$serial" shell /data/local/tmp/nvn_host_hooks_test
