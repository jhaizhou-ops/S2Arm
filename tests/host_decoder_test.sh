#!/bin/bash
# 门禁覆盖：pack/orch/host_decoder.py pack/orch/oneclick_win.py translator/uepak.py
# 要不要游戏自带解码器（Oodle / LZ5）的判定与 Windows 一键出包解包后退 75；见 tests/host_decoder_test.py（手写最小文件头夹具）
set -eu
R=$(cd "$(dirname "$0")/.." && pwd)
PY=${S2A_PYTHON:-${S2A_PY:-python3}}
cd "$R" && PYTHONUTF8=1 PYTHONWARNINGS=ignore::ResourceWarning "$PY" tests/host_decoder_test.py
