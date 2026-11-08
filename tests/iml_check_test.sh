#!/bin/bash
# iml_check 单测入口（门禁覆盖：pack/iml_check.py tests/iml_check_test.py）
# 门禁覆盖：pack/iml_check.py pack/iml_formats.py tests/iml_check_test.py pack/ipa.sh pack/oneclick/adhoc_sign.sh pack/dev_sign.py pack/jobs/ipa.py
set -u; H=$(cd "$(dirname "$0")/.." && pwd)
exec "${S2A_PY:-python3}" "$H/tests/iml_check_test.py"
