#!/bin/bash
# 开发者自愿执行的规范工具验证；不进入 tests/*_test.sh 门禁。
# 使用真实工具、仓库源文件和独立 Git index；不安装依赖，不替换日志或设备接口。
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo"
make format-check lint
"${STYLE_PYTHON:-build/style-venv/bin/python}" tests/style_integration.py
