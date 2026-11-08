#!/bin/bash
# 门禁覆盖：pack/ipa_tail.py pack/build_id.sh pack/app_bundle.py tests/test_ipa_tail.py
# 出包收尾单测（pack/ipa_tail.py：画面模式 / 着色器目标 / 包号 / Info.plist 实写 / 签名方式守卫，约 1 秒）：bash tests/ipa_tail_test.sh
cd "$(dirname "$0")/.." || exit 1
"${S2A_PY:-python3}" -B tests/test_ipa_tail.py
