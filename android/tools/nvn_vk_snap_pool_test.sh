#!/usr/bin/env bash
# 宿主回归：反馈快照池的复用/淘汰判据——在途帧的槽不可复用/不可淘汰，完成证明到手后才可复用。
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
cc=${CC:-cc}
out=$(mktemp -d "${TMPDIR:-/tmp}/s2a-snap-pool.XXXXXX")
trap 'rm -rf "$out"' EXIT
"$cc" -std=gnu11 -O1 -Wall -Wextra -Werror -Wno-unused-parameter \
    -I "$repo/android/native/nvn" \
    -o "$out/t" "$repo/android/tests/nvn_vk_snap_pool_test.c"
"$out/t"
