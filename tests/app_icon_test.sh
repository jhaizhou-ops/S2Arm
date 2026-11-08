#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# App 图标的跨平台原创夹具，不读取系统图标或游戏。
# 门禁覆盖：pack/app_bundle.py tests/test_app_bundle.py
cd "$(dirname "$0")/.." || exit 1
"${S2A_PY:-python3}" -I -B tests/test_app_bundle.py \
  BundleTests.test_icons_dimensions_color_and_plist \
  BundleTests.test_missing_and_empty_icon_leave_app_unchanged \
  BundleTests.test_corrupt_icon_is_red_before_writes
