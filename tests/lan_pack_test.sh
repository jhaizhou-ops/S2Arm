#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 门禁覆盖：tools/lan_pack.py tools/lan_pack_server.py tools/lan_pack_pull.py
# 局域网拉取资源包单测（本机起只读服务、参考客户端拉到临时目录，不连手机）：bash tests/lan_pack_test.sh
set -u; cd "$(dirname "$0")/.." || exit 1
python3 -B tests/lan_pack_test.py 2>&1 | tail -3; rc=${PIPESTATUS[0]}
[ "$rc" = 0 ] && echo "lan_pack 单测全过" || { echo "lan_pack 单测有不通"; exit 1; }
