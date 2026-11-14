#!/usr/bin/env bash
# 首用管线后台构建（android/native/nvn/nvn_vk_pipe_demand.c）宿主集成测：fake 建管线驱动后台线程。
# 覆盖 kick→PENDING→建→READY、二次命中、失败→FAILED、仅着色器不同不串管线（P0 回归）、停局有界。无 GPU。
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
cc="${CC:-cc}"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
incs=(-I "$repo/android/tests/vkhost" -I "$repo/android/tests/hostvk" -I "$repo/android/native" \
      -I "$repo/android/native/direct" -I "$repo/android/native/nvn" -I "$repo/runtime/include" \
      -I "$repo/graphics/nvn/gfx/nvn" -I "$repo/graphics/nvn/gfx/nvn/include" -I "$repo/graphics/nvn/gfx/tex" \
      -I "$repo/graphics/nvn/third_party/vulkan-headers/include" -I "$repo/graphics/nvn/replay")
srcs=("$repo/android/tests/nvn_vk_pipe_demand_test.c" "$repo/android/native/nvn/nvn_vk_pipe_demand.c" "$repo/android/native/nvn/nvn_pipe_pend.c")
"$cc" -std=gnu11 -O1 -g -pthread -Wall -Wextra -Werror "${incs[@]}" -o "$tmp/t" "${srcs[@]}"
"$tmp/t"
"$cc" -std=gnu11 -O1 -g -pthread -fsanitize=address -fno-omit-frame-pointer "${incs[@]}" -o "$tmp/ta" "${srcs[@]}"
ASAN_OPTIONS=detect_leaks=1 "$tmp/ta"
echo "demand: GREEN + ASan clean (ok)"
