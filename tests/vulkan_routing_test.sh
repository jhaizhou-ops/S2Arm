#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# Vulkan 容器入口的路由 / 退出码契约（tests/vulkan/container_test.py，假 docker，不起容器），宿主原生跑。
#   原先由 shader_cases_test.sh 在 amd64 模拟容器里跑：每例约 6 秒、写死 10 秒超时，11-02 假红（11-05 不稳定项 #12）。
# 门禁只看：tests/vulkan/* tests/shader_cases_test.sh android/tests/vk/run.sh
set -eu
R=$(cd "$(dirname "$0")/.." && pwd)
exec "${S2A_PY:-python3}" "$R/tests/vulkan/container_test.py" "$@"
