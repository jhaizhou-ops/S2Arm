#!/bin/bash
# 门禁覆盖：tools/public_repo_scan.py tools/public_repo_scan_rules.json tools/gate.sh tools/contrib_check.sh tools/gate_plan.sh tools/train.sh tests/public_repo_scan_test.py
# 原创合成夹具；不读真实游戏资源、不起真设备、不联网。
set -euo pipefail
cd "$(dirname "$0")/.."
python3 tests/public_repo_scan_test.py
echo '公开仓扫描：原创正负夹具与 doc 接线 → 全过'
