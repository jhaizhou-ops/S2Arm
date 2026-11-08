#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# Adapted from PR #209 (wdjwxh); main integration for #208.
# 门禁覆盖：tools/android_power.py
set -euo pipefail
H=$(cd "$(dirname "$0")/.." && pwd)
exec "${PYTHON:-python3}" "$H/tests/android_power_test.py"
