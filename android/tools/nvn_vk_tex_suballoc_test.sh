#!/usr/bin/env bash
# 宿主反例：纹理子分配的块归属/对齐/切分余量/跨块不串/满块失败。
# 第一版生产代码就是在这里错的：先搬末条覆盖本条、再读本条的偏移，回填成「别人的偏移 + 我的块」。
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
cc=${CC:-cc}
out=$(mktemp -d "${TMPDIR:-/tmp}/s2a-tex-suballoc.XXXXXX")
trap 'rm -rf "$out"' EXIT
"$cc" -std=gnu11 -O1 -Wall -Wextra -Werror \
    -I "$repo/android/native/nvn" \
    -o "$out/t" "$repo/android/tests/nvn_vk_tex_suballoc_test.c"
"$out/t"
