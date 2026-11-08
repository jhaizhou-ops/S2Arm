#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# Adapted from PR #209 (wdjwxh); main integration for #208.
# 门禁覆盖：android/core-runtime/metrics-tests/run.py android/core-runtime/metrics-tests/PresentWiring.cs.in android/core-runtime/metrics-tests/Program.cs android/core-runtime/metrics-tests/cli_test.py android/core-runtime/AndroidRunMetrics.cs android/metrics_contract.py android/metrics.py android/collect_run.py tests/android_metrics_adb_test.py tests/android_metrics_pipeline_test.py tests/android_metrics_test.py
set -euo pipefail
H=$(cd "$(dirname "$0")/.." && pwd)
"${PYTHON:-python3}" "$H/tests/android_metrics_adb_test.py"
"${PYTHON:-python3}" "$H/android/core-runtime/metrics-tests/cli_test.py"
exec "${PYTHON:-python3}" "$H/tests/android_metrics_test.py"
