#!/bin/bash
# 阶段真实输入记录单测（钩子 + 清单整理 + 按当前内容重算）：临时仓库里的假生成器，不读游戏数据
# 门禁覆盖：tools/stage_deps.py tools/stage_deps_hook/sitecustomize.py pack/stage_rewrite.sh
set -eu
R=$(cd "$(dirname "$0")/.." && pwd)
exec "${S2A_PY:-python3}" "$R/tests/stage_deps_test.py" "$@"
