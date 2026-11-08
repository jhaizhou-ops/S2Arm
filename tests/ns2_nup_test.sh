#!/bin/bash
# pack/ns2_nup.py 单测（tests/ns2_nup_test.py：按 NUP v1 规格拼合成容器，期望值是写进去的内容本身）+ 核 pack/oneclick/oneclick.sh 接 NUP 的那段：
#   源是 .nup 文件或文件夹里恰有一个 .nup → pack/ns2_nup.py 展开成导出目录 → 交 pack/ns2_dump.py
set -u
H=$(cd "$(dirname "$0")/.." && pwd)
PY=${S2A_PYTHON:-$HOME/.s2arm/venv/bin/python3}; [ -x "$PY" ] || PY=python3
"$PY" "$H/tests/ns2_nup_test.py"; r=$?
grep -q '"$PY" "$P/ns2_nup.py" "$NUPF" "$B/ns2_dump/$ND"' "$H/pack/oneclick/oneclick.sh" \
  && grep -q 'NS2D=$B/ns2_dump/$ND' "$H/pack/oneclick/oneclick.sh" || { echo "✗ oneclick.sh 没接 ns2_nup.py"; r=1; }
[ $r = 0 ] && echo "✓ t_ns2_nup"
exit $r
