#!/bin/bash
# 离线验证真机对拍的判据；不连接设备、不编译、不联网。
set -eu
cd "$(dirname "$0")/.."
PYTHONDONTWRITEBYTECODE=1 "${S2A_PY:-python3}" tests/rewrite_android_compare_test.py
