#!/bin/bash
# 双补丁岛合成金样（原生层 10-30）：近布局越线 → 前岛接住低地址单元；text > 128 MiB → 双岛 + brk 兜底 + 自旋够不着报红。
#   C 命令行（出包同一入口 pack/rewriter.py c-path）全部产物对金样（tests/rewrite_golden.py；10-31 前是与 Python 改写器逐字节对拍），期望值按布局公式手算（见 tests/rewrite_islands_test.py 文件头）
# 门禁覆盖：runtime/rewriter/* pack/rewriter.py tests/rewrite_golden.py tests/fixtures/rewrite_golden/*
set -u
H=$(cd "$(dirname "$0")/.." && pwd)
PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}   # 钉版解释器（tools/rewriter-requirements.txt）
S2A_PY=$PY "$PY" "$H/tests/rewrite_islands_test.py" || { echo "🔴 rewrite_islands_test：双补丁岛布局 / brk 兜底 / 产物与金样不符"; exit 1; }
echo "✅ 双补丁岛合成金样全过"
