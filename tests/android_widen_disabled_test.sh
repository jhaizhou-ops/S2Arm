#!/bin/bash
# 门禁只看：android/tools/make_pack.py graphics/widen/scan/wide_scan.py runtime/rewriter/rewriter.c tests/android_widen_disabled_test.py
set -euo pipefail
H=$(cd "$(dirname "$0")/.." && pwd)
"${S2A_PY:-python3}" "$H/tests/android_widen_disabled_test.py"
