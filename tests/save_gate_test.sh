#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 门禁覆盖：ios/save_gate.h ios/save_transfer.m tests/save_gate/
# iOS 存档页状态纯函数（审计 P0-1：恢复失败后开始游戏永久灰）：宿主 C 编译直跑，不要 UIKit / 真机
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d "${TMPDIR:-/tmp}/save_gate.XXXXXX"); trap 'rm -rf "$T"' EXIT
"${CC:-cc}" -std=c11 -Wall -Wextra -Werror -I"$R/ios" "$R/tests/save_gate/t_save_gate.c" -o "$T/t"
"$T/t"
