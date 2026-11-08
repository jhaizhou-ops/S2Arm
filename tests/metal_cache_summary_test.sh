#!/bin/bash
# 门禁覆盖：tools/metal_cache_summary.py tests/metal_cache_summary_test.py
set -eu
cd "$(dirname "$0")/.."
python3 tests/metal_cache_summary_test.py
echo '启动累计行、窗口边界、>100 ms 阈值、缺失采样不报零 → 通过'
