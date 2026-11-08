#!/bin/bash
# D1 采集/对比框架的单测入口：改到 graphics/nvn/tools/d1/ 时门禁自动跑它。
# 门禁只看：graphics/nvn/tools/d1/*
# 门禁覆盖：graphics/nvn/tools/d1/*
# 正文只做一件事：跑合成数据用例（不需要 Mac / GPU）。
set -eu
H=$(cd "$(dirname "$0")/.." && pwd)
python3 "$H/graphics/nvn/tools/d1/tests/test_d1.py"
