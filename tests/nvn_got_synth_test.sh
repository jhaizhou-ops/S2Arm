#!/bin/bash
# 门禁覆盖：graphics/nvn/tools/nvn_got_census.py graphics/nvn/tools/nvn_got_reads.py graphics/nvn/tools/loader_census.py graphics/nvn/tools/nso_fnmap.py graphics/nvn/tools/direct_census.py tests/nvn_got_census/* android/tools/selftest_nso.py
# 无游戏输入；运行真实编译的本仓库程序普查，不替代私有真实 NSO 回归。
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
exec "${S2A_PY:-python3}" "$ROOT/tests/nvn_got_synth_test.py" "$@"
