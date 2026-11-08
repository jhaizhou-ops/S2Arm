#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 门禁覆盖：runtime/src/det.c tests/det_host_queue.c
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests
link=(-Wl,--gc-sections)
[ "$(uname -s)" != Darwin ] || link=(-Wl,-dead_strip)
"${CC:-cc}" -std=gnu11 -O1 -g -Wall -Wextra -ffunction-sections -fdata-sections \
    -I runtime/include -pthread tests/det_host_queue.c "${link[@]}" -o build/tests/det_host_queue
build/tests/det_host_queue
build/tests/det_host_queue wrap
build/tests/det_host_queue fill
