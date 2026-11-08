#!/bin/bash
# 虚幻 4 控制台变量按名定位（tools/ue_cvar_loc.py）合成镜像单测：静态注册处 → 对象 +0x10；无帮助文本的引用不算；找不到退出 1
# 门禁覆盖：tools/ue_cvar_loc.py
set -u; H=$(cd "$(dirname "$0")/.." && pwd)
exec "${S2A_PY:-$HOME/.s2arm/venv/bin/python3}" "$H/tests/ue_cvar_loc_test.py"
