#!/bin/bash
# 门禁覆盖：graphics/nvn/tools/direct_census.py tests/direct_census_casc_test.py
set -eu
cd "$(dirname "$0")/.."
PY=${S2A_PY:-${PY:-$HOME/.s2arm/venv/bin/python3}}   # 钉版解释器（direct_census 经 profile_guess 用到 lz4），与其它工具单测一致
[ -x "$PY" ] || { echo "🔴 缺钉版解释器 ${PY}（tools/rewriter-requirements.txt 的 venv）"; exit 1; }
"$PY" tests/direct_census_casc_test.py
