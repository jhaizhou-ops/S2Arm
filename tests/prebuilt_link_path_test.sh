#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 门禁覆盖：services/prebuilt_lib.sh tests/prebuilt_link_path_test.py tools/nospace.sh
set -euo pipefail
cd "$(dirname "$0")/.."
python3 -B tests/prebuilt_link_path_test.py
