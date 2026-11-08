#!/bin/bash
# 门禁覆盖：pack/crosshost/ pack/contracts/compare.py pack/contracts/validate.py pack/contracts/artifact.v2.schema.json tests/test_crosshost_prepared.py
set -eu
cd "$(dirname "$0")/.."
"${S2A_CONTRACT_PY:-python3}" -I -S -B tests/test_crosshost_prepared.py
