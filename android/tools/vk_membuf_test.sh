#!/usr/bin/env bash
# vk_membuf.c 的宿主单测（fake Vulkan，确定性，不需要 GPU / Android 设备）。
# 覆盖：能力探测字段映射、UPLOAD 分配与 cache 维护、host import 五类拒绝与成功、
# 错误路径无半分配、destroy 释放顺序、selftest 的 CPU 写→GPU 读数据流（含负对照）。
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
android="$repo/android"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cc_bin="${CC:-cc}"
"$cc_bin" -std=gnu11 -O1 -Wall -Wextra -Werror -Wno-unused-parameter \
  -I "$android/native" -I "$android/native/direct" \
  -I "$android/tests/vkhost" -I "$android/tests/hostvk" \
  -I "$repo/graphics/nvn/third_party/vulkan-headers/include" \
  -o "$tmp/vk_membuf_test" \
  "$android/tests/vk_membuf_test.c" "$android/native/direct/vk_membuf.c"
"$tmp/vk_membuf_test"
