#!/bin/bash
# 门禁覆盖：tools/beta_intake.py tests/beta_intake_metrickit_test.py
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
exec "${S2A_PYTHON:-python3}" "$ROOT/tests/beta_intake_metrickit_test.py"
