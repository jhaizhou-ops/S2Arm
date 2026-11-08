#!/bin/bash
# 社区同构建号帧率条目转帧率表单测（合成条目，不读游戏数据、不带补丁原文）
# 门禁覆盖：tools/fps_warehouse.py
set -eu
R=$(cd "$(dirname "$0")/.." && pwd)
exec "${S2A_PY:-python3}" "$R/tests/fps_warehouse_test.py" "$@"
