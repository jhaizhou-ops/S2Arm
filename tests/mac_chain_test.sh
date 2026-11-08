#!/bin/bash
# G1：用临时最小索引验证起局核链，不需要游戏资料，不启动游戏。
# 门禁覆盖：runtime/run_mac.sh tools/mac_chain_check.py graphics/nvn/gfx/nvn/dmsh_chain.h
# 可选真实库验证：S2A_CHAIN_MATCH_LIB=<同链目录> S2A_CHAIN_MISMATCH_LIB=<异链目录> python3 -B tests/mac_chain_real_manual.py "$PWD"
set -eu
R=$(cd "$(dirname "$0")/.." && pwd)
python3 -B "$R/tests/mac_chain_test.py" "$R"
