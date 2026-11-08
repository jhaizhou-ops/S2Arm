#!/bin/bash
# 门禁覆盖：tools/readback_report.py tests/test_readback_report.py
# 读回报告（tools/readback_report.py）的门禁入口：门禁只枚举 tests/*_test.sh，这里转给合成单测 tests/test_readback_report.py
set -eu
R=$(cd "$(dirname "$0")/.." && pwd)
PY=${S2A_PYTHON:-${S2A_PY:-python3}}
cd "$R"   # 单测内部按相对路径调 tools/readback_report.py
exec "$PY" tests/test_readback_report.py "$@"
