#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 门禁覆盖：tools/input_caps_register.py tools/reglist.py tests/input_caps_register_test.py
set -eu
R=$(cd "$(dirname "$0")/.." && pwd)
PYTHONDONTWRITEBYTECODE=1 "${S2A_PY:-python3}" "$R/tests/input_caps_register_test.py"
