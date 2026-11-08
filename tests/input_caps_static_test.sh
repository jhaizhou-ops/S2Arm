#!/bin/bash
# Offline original NSO fixtures only; no game data, device or network access.
# 门禁覆盖：tools/input_caps_static.py graphics/nvn/tools/nso_syms.py graphics/nvn/tools/direct_profile.py graphics/nvn/tools/lz4blk.py
set -eu
R=$(cd "$(dirname "$0")/.." && pwd)
PY=${S2A_PYTHON:-${S2A_PY:-python3}}
exec "$PY" "$R/tests/input_caps_static_test.py" "$@"
