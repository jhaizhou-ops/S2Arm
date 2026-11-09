#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 门禁只看：tools/ci_readme_plan.py .github/workflows/ci.yml tests/ci_readme_plan_test.py
set -euo pipefail
cd "$(dirname "$0")/.."
python3 tests/ci_readme_plan_test.py
