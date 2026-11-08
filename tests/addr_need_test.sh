#!/bin/bash
# 地址需求表（tools/addr_need.py）合成 NSO / NPDM 单测：只按 main 代码特征静态识别开局巨大别名区，普通堆 = 应用池上限；调用方不传逐款表、不读跑局日志（pack/stage_rewrite.sh、pack/jobs/build.py、android/tools/make_pack.py）
# 门禁覆盖：tools/addr_need.py pack/srcs.sh pack/stage_rewrite.sh pack/jobs/build.py android/tools/make_pack.py
set -u; H=$(cd "$(dirname "$0")/.." && pwd)
exec "${S2A_PY:-$HOME/.s2arm/venv/bin/python3}" "$H/tests/addr_need_test.py"
