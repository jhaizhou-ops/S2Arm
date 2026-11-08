#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# Host Java method-boundary regression; no Android SDK or device is simulated.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
PY=${S2A_PY:-${PY:-python3}}
"$PY" "$here/exit_order_test.py"
