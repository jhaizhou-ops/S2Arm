#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
android="$repo/android"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
"${CC:-cc}" -std=gnu11 -O1 -Wall -Wextra -Werror -Wno-unused-parameter \
  -I "$android/native" -I "$android/native/nvn" \
  -o "$tmp/t" "$android/tests/vk_poolahb_alias_test.c" "$android/native/nvn/poolahb_alias.c"
"$tmp/t"
