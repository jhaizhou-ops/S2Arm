#!/bin/bash
# 门禁覆盖：translator/vk_shaders.py tests/vk_shaders_rsp_test.py
# vk_shaders.py 合库走响应文件（Windows 命令行长度上限，11-06 天眼银河 2）：外部命令替身，约 1 秒；见 tests/vk_shaders_rsp_test.py
set -eu
cd "$(dirname "$0")/.." && python3 tests/vk_shaders_rsp_test.py
