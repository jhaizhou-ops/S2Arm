#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 门禁覆盖：pack/jobs/winenv.py pack/jobs/tests/test_winenv.py pack/jobs/toolchain.py pack/jobs/ipa.py launchers/macos/requirements-runtime.txt compat/tree/global.json tools/redact.py translator/dmsh_chain.lock
cd "$(dirname "$0")/.." || exit 1
py=python3
if [ -n "${S2A_PY:-}" ]; then py=$S2A_PY; fi
"$py" -I -B pack/jobs/tests/test_winenv.py
