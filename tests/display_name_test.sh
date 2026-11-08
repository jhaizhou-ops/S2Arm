#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 门禁覆盖：pack/display_name.py pack/ipa.sh pack/oneclick/oneclick.sh pack/jobs/install.py android/tools/game_apk.py tests/test_display_name.py
# 装机 App 显示名唯一来源 = 游戏自带 control.nacp 标题（11-04 jhz）：语言优先级、目录形态、后缀、新格式压缩表、取不到报红；各出包入口都接这一个函数
cd "$(dirname "$0")/.." || exit 1
"${S2A_PY:-python3}" -I -B tests/test_display_name.py
