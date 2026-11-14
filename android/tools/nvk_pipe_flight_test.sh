#!/usr/bin/env bash
# 配方级在途表（android/native/nvn/nvn_pipe_flight.c）宿主单测：同配方合并 / 不同配方不排队 / 失败传播 /
# 表满 / 认领后复检命中。纯逻辑，无 GPU。
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
cc="${CC:-cc}"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
"$cc" -std=gnu11 -O1 -Wall -Wextra -Werror -pthread -D_GNU_SOURCE \
  -I "$repo/android/native/nvn" \
  -o "$tmp/t" "$repo/android/tests/nvn_pipe_flight_test.c" "$repo/android/native/nvn/nvn_pipe_flight.c"
"$tmp/t"
