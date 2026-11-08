#!/usr/bin/env bash
# 池后备迁移的地址覆盖判定（宿主，确定性）。只编纯逻辑实现，不需要 Vulkan/Android 头。
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
android="$repo/android"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cc_bin="${CC:-cc}"
"$cc_bin" -std=gnu11 -O1 -Wall -Wextra -Werror -Wno-unused-parameter \
  -I "$android/native" -I "$android/native/nvn" \
  -o "$tmp/t" "$android/tests/vk_poolahb_cover_test.c" "$android/native/nvn/poolahb_cover.c"
"$tmp/t"
