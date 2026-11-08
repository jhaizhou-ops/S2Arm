#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 真实 C CLI：编码缺口退出 3 不得留下上一轮运行产物；保留本轮诊断。
# 门禁覆盖：runtime/rewriter/rewriter.c tests/rewrite_gap_outputs_test.py
set -euo pipefail
H=$(cd "$(dirname "$0")/.." && pwd)
PY=${PY:-${S2A_PY:-python3}}
REW=${REW:-$("$PY" "$H/pack/rewriter.py" c-path)}
"$PY" "$H/tests/rewrite_gap_outputs_test.py" "$REW"
