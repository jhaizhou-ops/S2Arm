#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 门禁覆盖：pack/orch/stages.py pack/orch/refresh.py tests/orch_stages_light_test.py
set -eu
H=$(cd "$(dirname "$0")/.." && pwd)
PY=${S2A_PY:-python3}
PYTHONUTF8=1 "$PY" "$H/tests/orch_stages_light_test.py" -v
