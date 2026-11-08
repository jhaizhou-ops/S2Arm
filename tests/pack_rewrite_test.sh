#!/bin/bash
# C 默认改写入口：真实 C / Python + 公开合成 NSO；不联网、不用游戏。
# 门禁覆盖：pack/stage_rewrite.sh pack/rewriter.py runtime/rewriter/* tests/rewrite_apple_golden_test.sh
set -eu
H=$(cd "$(dirname "$0")/.." && pwd)
PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}   # 钉版解释器（capstone / lz4，同 rewrite_apple_golden_test.sh）：mini 的系统 python3 没有 lz4
"$PY" "$H/tests/pack_rewrite_test.py"
