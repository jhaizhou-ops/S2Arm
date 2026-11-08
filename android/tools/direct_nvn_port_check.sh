#!/usr/bin/env bash
# C5 前置：共享 NVN 前端在 Android/ARM64 的可编译性检查。
# 只编对象，不链接、不运行；证明 Apple 依赖已有兼容层，不声称前端可执行。
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
. "$(dirname "$0")/ndk_toolchain.sh"
ndk=$(s2a_ndk_resolve) || { echo "no NDK; NVN port check NOT RUN" >&2; exit 2; }
cc=$(s2a_ndk_clang "$ndk" 29) || { echo "no NDK clang for this host; NVN port check NOT RUN" >&2; exit 2; }
out=$(mktemp -d "${TMPDIR:-/tmp}/s2a-nvn-port.XXXXXX")
trap 'rm -rf "$out"' EXIT
flags=(-std=gnu11 -O2 -Wno-format -Wno-unused-function -Wno-unused-variable
  -I "$repo/android/native/nvn/compat"
  -I "$repo/android/native/direct"
  -I "$repo/graphics/nvn/gfx/nvn" -I "$repo/graphics/nvn/gfx/nvn/include"
  -I "$repo/graphics/nvn/gfx/nvn/host" -I "$repo/graphics/nvn" -I "$repo/runtime/include")
"$cc" "${flags[@]}" -c "$repo/graphics/nvn/gfx/nvn/hle_nvn.c" -o "$out/hle_nvn.o"
"$cc" "${flags[@]}" -c "$repo/android/native/nvn/portable.c" -o "$out/portable.o"
# BSD/macOS 的 stat 没有 -c；用 wc 取字节数，两种宿主都能跑。
echo "NVN frontend Android compile: ok ($(wc -c < "$out/hle_nvn.o" | tr -d ' ') B object; link/run not claimed)"
