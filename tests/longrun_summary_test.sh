#!/bin/bash
# 长局 host.log 五分钟趋势汇总（tools/longrun_summary.py）的合成样本单测；纯标准库 Python 3。门禁只发现 tests/*_test.sh，这里转给同名 .py
set -eu
R=$(cd "$(dirname "$0")/.." && pwd)
PY=${S2A_PYTHON:-${S2A_PY:-python3}}
exec "$PY" "$R/tests/longrun_summary_test.py" "$@"
