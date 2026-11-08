#!/bin/bash
# 门禁覆盖：pack/shell/ pack/contracts/compare.py pack/contracts/validate.py pack/contracts/artifact.v2.schema.json tests/test_shell_manifest.py
# 壳的发版清单单测（pack/shell/manifest.py，Windows 全流程出包 #1123，约 1 秒）：bash tests/shell_manifest_test.sh
cd "$(dirname "$0")/.." || exit 1
"${S2A_CONTRACT_PY:-python3}" -I -S -B tests/test_shell_manifest.py
