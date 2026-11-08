#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 门禁预算：1200
# 门禁只看：tests/shader_cases/* tests/vulkan/* compat/tree/src/Ryujinx.Graphics.Shader/* compat/tree/src/Spv.Generator/* compat/patches/* android/native/direct/vk_device.c android/native/direct/vk_device.h android/native/direct/gs_path.c android/native/direct/gs_path.h
# 门禁本机：Linux 直接执行；macOS 用本机 colima 中已准备的公共 Vulkan 镜像，mini 不具备此环境
# 门禁输入：compat/tree/src/Ryujinx.Common/*
set -euo pipefail
H=$(cd "$(dirname "$0")/.." && pwd)
if [ "$(uname -s)" = Darwin ]; then
  exec bash "$H/tests/vulkan/run.sh" tests/shader_cases_test.sh
fi
# 路由契约 container_test.py 已拆成宿主原生的 tests/vulkan_routing_test.sh（11-05 不稳定项 #12），不再进模拟容器
python3 "$H/tests/shader_cases/budget_test.py"
python3 "$H/tests/shader_cases/coverage_test.py"
python3 "$H/tests/shader_cases/runner_test.py"
python3 "$H/tests/shader_cases/integer/logic_reference_test.py"
python3 "$H/tests/shader_cases/integer/shift_reference_test.py"
python3 "$H/tests/shader_cases/integer/bitfield_reference_test.py"
python3 "$H/tests/shader_cases/integer/add_reference_test.py"
python3 "$H/tests/shader_cases/integer/mul_reference_test.py"
python3 "$H/tests/shader_cases/integer/mul_encoding_test.py"
python3 "$H/tests/shader_cases/integer/xmad_reference_test.py"
python3 "$H/tests/shader_cases/float/addmul_reference_test.py"
python3 "$H/tests/shader_cases/float/fma_reference_test.py"
python3 "$H/tests/shader_cases/float/fset_reference_test.py"
python3 "$H/tests/shader_cases/float/fset_encoding_test.py"
python3 "$H/tests/shader_cases/float/i2f_reference_test.py"
python3 "$H/tests/shader_cases/float/i2f_encoding_test.py"
python3 "$H/tests/shader_cases/float/f2i_reference_test.py"
python3 "$H/tests/shader_cases/float/f2i_encoding_test.py"
python3 "$H/tests/shader_cases/flow/reference_model.py"   # 11-01 接线：flow 用例独立参考模型（逐字对期望 + 一位错期望必须被拒），纯 Python 不到 1 秒
python3 "$H/tests/shader_cases/run.py"
