#!/bin/bash
# 门禁只看：android/tools/make_pack.py tests/android_ui_overlay_test.py
set -euo pipefail
H=$(cd "$(dirname "$0")/.." && pwd)
"${S2A_PY:-python3}" "$H/tests/android_ui_overlay_test.py"
