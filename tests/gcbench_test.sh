#!/bin/bash
# GC 扫描记账离线单测（tests/gcbench/test_scan.py：只核 scan.py 的证据记账，不计时、不编 NativeAOT，约 1 秒）
# 11-01 接线：同目录 test.sh 要先联网 build.sh --restore 才能跑，记账单测原先没人调；这里只接离线这支。
# 门禁覆盖：tests/gcbench/*
set -u; H=$(cd "$(dirname "$0")/.." && pwd)
exec python3 "$H/tests/gcbench/test_scan.py"
