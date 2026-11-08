#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 门禁覆盖：pack/shell/ pack/contracts/compare.py pack/contracts/validate.py pack/contracts/artifact.v2.schema.json tests/test_shell_cache.py
cd "$(dirname "$0")/.." || exit 1
"${S2A_CONTRACT_PY:-python3}" -I -S -B tests/test_shell_cache.py
