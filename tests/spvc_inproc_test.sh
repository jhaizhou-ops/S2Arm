#!/bin/bash
# spirv-cross 命令行编成动态库在进程内跑（translator/spvc_inproc.py）：与命令行逐字节相同、出错不带走调用进程、多线程不串
# 门禁覆盖：translator/spvc_inproc.py translator/spvc_cli/* graphics/third_party/spirv_cross/* tests/spvc_inproc_test.py
set -eu
R=$(cd "$(dirname "$0")/.." && pwd)
PY=${S2A_PY:-${PY:-$HOME/.s2arm/venv/bin/python3}}
exec "$PY" "$R/tests/spvc_inproc_test.py"
