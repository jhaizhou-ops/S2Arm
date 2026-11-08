#!/bin/bash
# 门禁覆盖：tools/tianyan_lane.py pack/orch/oneclick_win.py pack/orch/refresh.py
# 天眼道带真机转储着色器（--rt-shaders，内部验证包通道）+ Windows 播种带 rt_shaders；见 tests/tianyan_rt_shaders_test.py
set -eu
R=$(cd "$(dirname "$0")/.." && pwd)
PY=${S2A_PYTHON:-${S2A_PY:-python3}}
cd "$R" && PYTHONUTF8=1 PYTHONWARNINGS=ignore::ResourceWarning "$PY" tests/tianyan_rt_shaders_test.py
