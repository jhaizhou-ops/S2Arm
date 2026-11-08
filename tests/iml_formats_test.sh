#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 门禁覆盖：pack/iml_check.py pack/iml_formats.py tests/iml_formats_test.py
set -eu
H=$(cd "$(dirname "$0")/.." && pwd)
exec "${S2A_PY:-python3}" "$H/tests/iml_formats_test.py"
