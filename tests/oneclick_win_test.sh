#!/bin/bash
# 门禁覆盖：pack/orch/oneclick_win.py pack/orch/install_win.py pack/source_pick.py pack/oneclick/oneclick.sh
# Windows 一键出包（天眼道）入口与共用选款模块：选款规则、环境自检缺件退 75、工作根只联接不拷；见 tests/oneclick_win_test.py
set -eu
R=$(cd "$(dirname "$0")/.." && pwd)
PY=${S2A_PYTHON:-${S2A_PY:-python3}}
cd "$R" && PYTHONUTF8=1 PYTHONWARNINGS=ignore::ResourceWarning "$PY" tests/oneclick_win_test.py
echo "✓ Windows 一键出包单测全过"
