#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# No source copy or cached object: always rebuild against the current native encoder.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
android=$(cd "$here/.." && pwd)
repo=$(cd "$android/.." && pwd)
[ "$#" = 1 ] || { echo 'usage: build_direct_identity_host.sh OUTPUT' >&2; exit 2; }
"${CC:-cc}" -std=c11 -O2 -Wall -Wextra -Werror \
  -I"$android/native" -I"$repo/runtime/include" -I"$repo/graphics/nvn/gfx/nvn/include" \
  "$here/direct_identity_host.c" "$android/native/direct/input_identity.c" \
  "$android/native/direct/texture_facts.c" "$android/native/direct/sha256.c" \
  "$android/native/direct/json.c" -lm -o "$1"
