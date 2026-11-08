#!/bin/bash
# 验证账（贡献者 / 我方快检报告入账）单测：合成报告，不调 AI、不碰游戏数据
# 门禁覆盖：tools/caps_ledger.py
set -eu
R=$(cd "$(dirname "$0")/.." && pwd)
exec "${S2A_PY:-python3}" "$R/tests/caps_ledger_test.py" "$@"
