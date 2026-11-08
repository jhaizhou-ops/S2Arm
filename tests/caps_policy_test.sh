#!/bin/bash
# caps_policy 引擎通用第一层来源单测（假引擎推导，不读游戏数据）
# 门禁覆盖：tools/caps_policy.py tools/caps_ledger.py
set -eu
R=$(cd "$(dirname "$0")/.." && pwd)
"${S2A_PY:-python3}" "$R/tests/caps_apple_compat_test.py"
exec "${S2A_PY:-python3}" "$R/tests/caps_policy_test.py" "$@"
