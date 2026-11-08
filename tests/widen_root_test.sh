#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 门禁覆盖：pack/ipa.sh pack/widen_root.py tests/widen_root_test.py tools/addr_need.py
set -eu
H=$(cd "$(dirname "$0")/.." && pwd)
"${S2A_PY:-python3}" "$H/tests/widen_root_test.py"
