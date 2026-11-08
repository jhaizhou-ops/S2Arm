#!/bin/bash
# 门禁覆盖：tools/push_pack.py tools/push_pack.sh
# 推资源包规则单测（Mac / Windows 共用的 tools/push_pack.py；假设备在内存里，不连手机）：bash tests/push_pack_test.sh
set -u; cd "$(dirname "$0")/.." || exit 1
python3 -B tests/push_pack_test.py 2>&1 | tail -3; rc=${PIPESTATUS[0]}
[ "$rc" = 0 ] && echo "push_pack 单测全过" || { echo "push_pack 单测有不通"; exit 1; }
