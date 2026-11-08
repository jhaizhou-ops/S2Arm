#!/usr/bin/env bash
# 直连逐帧帧时间（宿主，确定性）：环形语义 / 丢弃与计数可见 / 分片转储字节级核回。
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
android="$repo/android"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
"${CC:-cc}" -std=gnu11 -O1 -Wall -Wextra -Werror -Wno-unused-parameter -pthread \
  -I "$android/native" -I "$android/native/nvn" -I "$android/native/direct" \
  -o "$tmp/t" "$android/tests/nvn_vk_frame_log_test.c" "$android/native/direct/sha256.c"
"$tmp/t"
