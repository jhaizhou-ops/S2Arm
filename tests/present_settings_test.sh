#!/bin/bash
# 门禁只看：graphics/nvn/gfx/nvn/nvn_mtl.m graphics/nvn/gfx/nvn/nvn_present_aa.inc graphics/nvn/Makefile graphics/nvn/tests/t_present_settings.* macos/front_mac.m graphics/metal/shaders/aa_* graphics/metal/tools/embed_* tests/present_settings_test.sh
# 门禁预算：600
# 门禁显卡：独占
# 上屏设置矩阵（graphics/nvn/tests/t_present_settings.sh：M3 / M4 × 四种抗锯齿 × 三种过滤，真上屏器、GPU 现生成输入、逐像素独立判）的合入前入口，本机约 2.5 分钟
# 11-06 维护者：graphics/gate.sh 是「门禁层：合入后」，列车合入前不跑它；Switch2 线 fix/host-upstream-c 改 nvn_mtl.m（e634b53e4 sRGB / 线性孪生贴图）
#   11:34 入车时这组一次没跑，13:41 守望才发现矩阵 0/18，二分到 15:07。触发路径同 graphics/gate.sh 的 need_present_settings，改到它们的支入车就跑；
#   整份 gfx 钩子仍在合入后那层，不动分层
set -u
cd "$(dirname "$0")/.." || exit 1
exec bash graphics/nvn/tests/t_present_settings.sh
