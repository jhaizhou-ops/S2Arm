#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 门禁覆盖：ios/ldn_lan.m ios/lan_permission.m
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
python3 "$R/tests/lan_permission_test.py"
