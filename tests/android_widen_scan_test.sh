#!/bin/bash
# 门禁只看：android/tools/make_pack.py graphics/widen/scan/wide_scan.py tests/android_widen_scan_test.py
# Android 宽屏扫描失败拒绝出包；合法空表仍交改写器。
set -eu
H=$(cd "$(dirname "$0")/.." && pwd)
python3 "$H/tests/android_widen_scan_test.py"
