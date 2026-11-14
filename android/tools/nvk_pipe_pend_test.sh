#!/usr/bin/env bash
# 首用待定表（android/native/nvn/nvn_pipe_pend.c）宿主单测：状态转移 / 同键合并 / 有界等待 / late-stuck / 满表淘汰。
# 负对照：-DNVK_PP_NEG_NO_DEDUP 关掉同键合并 → follow 用例必须变红（证明测试有效）。纯逻辑，无 GPU。
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
cc="${CC:-cc}"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
"$cc" -std=gnu11 -O1 -g -Wall -Wextra -Werror -pthread \
  -I "$repo/android/native/nvn" \
  -o "$tmp/t" "$repo/android/tests/nvn_pipe_pend_test.c" "$repo/android/native/nvn/nvn_pipe_pend.c"
"$tmp/t"
"$cc" -std=gnu11 -O1 -g -pthread -DNVK_PP_NEG_NO_DEDUP \
  -I "$repo/android/native/nvn" \
  -o "$tmp/tn" "$repo/android/tests/nvn_pipe_pend_test.c" "$repo/android/native/nvn/nvn_pipe_pend.c"
if "$tmp/tn"; then echo "negative control did NOT go red (dedup removal not detected)" >&2; exit 1; fi
echo "pend: GREEN + negative control RED (ok)"
