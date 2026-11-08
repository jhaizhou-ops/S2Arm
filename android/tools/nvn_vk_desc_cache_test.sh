#!/usr/bin/env bash
# 宿主回归：描述符 set 帧内复用的命中条件。必须证明「该命中的命中、不该命中的不命中」：
# 不同 offset/range、布局或池代际变化、跨帧、强制哈希碰撞都要拒绝；重复登记不改写已登记的 set。
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
cc=${CC:-cc}
out=$(mktemp -d "${TMPDIR:-/tmp}/s2a-desc-cache.XXXXXX")
trap 'rm -rf "$out"' EXIT
"$cc" -std=gnu11 -O1 -Wall -Wextra -Werror \
    -I "$repo/android/native/nvn" \
    -o "$out/t" "$repo/android/tests/nvn_vk_desc_cache_test.c"
"$out/t"
