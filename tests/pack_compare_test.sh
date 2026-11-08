#!/bin/bash
# 门禁覆盖：pack/contracts/compare.py tests/pack_compare_test.py
set -eu
cd "$(dirname "$0")/.."
python3 -I -B tests/pack_compare_test.py
