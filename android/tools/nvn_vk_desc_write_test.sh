#!/usr/bin/env bash
# 宿主回归：描述符写入初始化必须整结构清零（含 dstArrayElement），三路描述符各测一遍，
# 并用「漏字段」反例证明用例能抓到回归。
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
cc=${CC:-cc}
out=$(mktemp -d "${TMPDIR:-/tmp}/s2a-desc-write.XXXXXX")
trap 'rm -rf "$out"' EXIT
vkh="$repo/graphics/nvn/third_party/vulkan-headers/include"
"$cc" -std=gnu11 -O1 -Wall -Wextra -Werror -Wno-unused-parameter \
    -I "$repo/android/tests/vkhost" -I "$vkh" -I "$repo/android/native/nvn" \
    -o "$out/t" "$repo/android/tests/nvn_vk_desc_write_test.c"
"$out/t"
