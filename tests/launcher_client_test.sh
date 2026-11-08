#!/bin/bash
# 门禁覆盖：launchers/shared/launcher_client/* launchers/linux/* pack/jobs/main.py pack/jobs/core.py
set -eu
R=$(cd "$(dirname "$0")/.." && pwd)
PY=${S2A_PYTHON:-${S2A_PY:-python3}}
# tools/gate.sh enumerates tests/*_test.sh; this entry is selected by coverage.
# 门禁摘要只取最后一行（11-01 无缓存实跑红只留下「FAILED (failures=1)」，查不到是哪个用例）：失败时把 FAIL / ERROR 的用例名与首条断言并成最后一行
T=$(mktemp); trap 'rm -f "$T"' EXIT
fail() { echo "launcher_client $1 不通：$(grep -aE '^(FAIL|ERROR): |^(AssertionError|.*Error): ' "$T" | head -4 | tr '\n' ' ')"; exit 1; }
"$PY" -B "$R/launchers/shared/launcher_client/tests/t_client.py" -v 2>&1 | tee "$T"; [ "${PIPESTATUS[0]}" = 0 ] || fail t_client.py
"$PY" -B "$R/launchers/shared/launcher_client/tests/t_runtime.py" -v 2>&1 | tee "$T"; [ "${PIPESTATUS[0]}" = 0 ] || fail t_runtime.py
