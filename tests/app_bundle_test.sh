#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 门禁覆盖：pack/app_bundle.py pack/ipa.sh pack/oneclick/oneclick.sh launchers/macos/requirements-runtime.txt pack/shell/manifest.py tests/test_app_bundle.py
cd "$(dirname "$0")/.." || exit 1
"${S2A_PY:-python3}" -I -B tests/test_app_bundle.py
