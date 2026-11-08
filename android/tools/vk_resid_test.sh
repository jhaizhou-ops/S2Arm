#!/usr/bin/env bash
# 资源身份账本 + VM 替页事务的宿主反例（确定性，不需要 Vulkan/真机）。
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
android="$repo/android"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cc_bin="${CC:-cc}"
"$cc_bin" -std=gnu11 -O1 -Wall -Wextra -Werror -Wno-unused-parameter \
  -I "$android/native" -I "$android/native/direct" \
  -o "$tmp/vk_resid_test" \
  "$android/tests/vk_resid_test.c" "$android/native/direct/vk_resid.c"
"$tmp/vk_resid_test"
