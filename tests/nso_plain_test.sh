#!/bin/bash
# 门禁覆盖：tools/nso_plain.py pack/nx_unpack/* tools/nso_sym.py
# Python 侧 NSO 读取方的 ZBIC 规整（tools/nso_plain.py → nx_unpack --nso-normalize）：合成 ZBIC NSO 规整后三段 = 合成原文、读取方铺出的映像与不压缩同内容一致、
#   不带 0x80 不调 nx_unpack、坏数据 / 假 ZBIC 报红。要 dotnet（nx_unpack 按源码哈希编进 run 区 bin/，与 pack/srcs.sh 共用）。退出 0 = 全过
set -u
H=$(cd "$(dirname "$0")" && pwd)
timeout 600 python3 "$H/nso_plain_test.py"
