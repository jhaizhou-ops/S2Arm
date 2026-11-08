#!/bin/bash
# C5 合成布局单测；Python 标准库，无游戏、设备或网络。
# 门禁覆盖：pack/jobs/save_formats.py pack/jobs/tests/test_save_formats.py
set -euo pipefail
H=$(cd "$(dirname "$0")/.." && pwd)
python3 -B "$H/pack/jobs/tests/test_save_formats.py" -v
