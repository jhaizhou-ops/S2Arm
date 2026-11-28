#!/bin/bash
# 门禁覆盖：pack/orch/oneclick_win.py pack/jobs/patches.py
# Windows 出包机道交管线种子（统一包 kind=pso → S2A_PSO_SOURCES_EXTRA，同启动器）；见 tests/oneclick_win_pso_seed_test.py
set -eu
R=$(cd "$(dirname "$0")/.." && pwd)
PY=${S2A_PYTHON:-${S2A_PY:-python3}}
cd "$R" && PYTHONUTF8=1 "$PY" tests/oneclick_win_pso_seed_test.py
echo "✓ Windows 出包机道管线种子单测全过"
