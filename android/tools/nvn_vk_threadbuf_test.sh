#!/usr/bin/env bash
# nvn_vk_threadbuf（每线程惰性分配 + 线程退出归还）的宿主单测。
# 真实现编进测试：线程退出时 pthread_key 析构必须归还（live 归零）、同线程复用、扩容保留内容。
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
android="$repo/android"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cc_bin="${CC:-cc}"
"$cc_bin" -std=gnu11 -O1 -Wall -Wextra -Werror -Wno-unused-parameter -pthread \
  -I "$android/native" -I "$android/native/nvn" -I "$android/tests/vkhost" \
  -o "$tmp/nvn_vk_threadbuf_test" \
  "$android/tests/nvn_vk_threadbuf_test.c" \
  "$android/native/nvn/nvn_vk_threadbuf.c"
"$tmp/nvn_vk_threadbuf_test"
echo "nvn-vk-threadbuf: 全部用例通过"
