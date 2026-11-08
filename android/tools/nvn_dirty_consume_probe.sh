#!/usr/bin/env bash
# 页级写跟踪消费语义自测（真机）：guest 写 → 缺页 → 记脏 → 代数判断。
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
. "$(dirname "$0")/ndk_toolchain.sh"
ndk=$(s2a_ndk_resolve) || { echo "no NDK; dirty probe NOT RUN" >&2; exit 2; }
serial=${S2A_ADB:-$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')}
[ -n "$serial" ] || { echo "no adb device; dirty probe NOT RUN" >&2; exit 2; }
cc=$(s2a_ndk_clang "$ndk" 29) || { echo "no NDK clang; dirty probe NOT RUN" >&2; exit 2; }
out=$(mktemp -d "${TMPDIR:-/tmp}/s2a-nvn-dirty.XXXXXX")
trap 'rm -rf "$out"' EXIT
"$cc" -std=c11 -O2 -Wall -Wextra -Wno-missing-field-initializers \
    -I "$repo/android/native/nvn/compat" -I "$repo" -I "$repo/runtime/include" -I "$repo/runtime/src" \
    -I "$repo/graphics/track" -I "$repo/graphics/nvn/host" -I "$repo/graphics/nvn/gfx/nvn" \
    -o "$out/nvn_dirty_consume_test" "$repo/android/tests/nvn_dirty_consume_test.c" \
    "$repo/graphics/nvn/gfx/nvn/nvn_dirty.c" "$repo/android/native/nvn/nvn_host_hooks.c" \
    "$repo/runtime/src/direct_host.c" -llog
adb -s "$serial" push "$out/nvn_dirty_consume_test" /data/local/tmp/ >/dev/null
adb -s "$serial" shell chmod 755 /data/local/tmp/nvn_dirty_consume_test
adb -s "$serial" shell /data/local/tmp/nvn_dirty_consume_test
