#!/bin/bash
# 门禁覆盖：pack/orch/oneclick_win.py tools/direct_cache_lru.py
# Windows 一键出包（天眼道）常驻直连缓存：按款路径、同款文件锁、日志拷回、按预算淘汰不动在用款；见 tests/oneclick_win_dcache_test.py
set -eu
R=$(cd "$(dirname "$0")/.." && pwd)
PY=${S2A_PYTHON:-${S2A_PY:-python3}}
cd "$R" && PYTHONUTF8=1 PYTHONWARNINGS=ignore::ResourceWarning "$PY" tests/oneclick_win_dcache_test.py > /dev/null
echo "✓ 天眼常驻直连缓存单测全过"
