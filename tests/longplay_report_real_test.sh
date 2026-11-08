#!/bin/bash
# 门禁覆盖：tools/longplay_report.py
# longplay_report_real_test.py 的门禁壳（10-29 基础设施线：门禁只自动收 tests/*_test.sh，这支 .py 原先没人调）
H=$(cd "$(dirname "$0")/.." && pwd)
exec "${S2A_PY:-python3}" "$H/tests/longplay_report_real_test.py"
