#!/bin/bash
# 门禁覆盖：pack/orch/*.py pack/roots.sh pack/stage_rewrite.sh pack/stage_keyfiles.sh pack/rewriter.py pack/cpatch.py pack/pkg_srcs.py tools/addr_need.py tools/nso_plain.py tools/stage_deps.py graphics/nvn/tools/romfs_list.py tests/orch_stages_test.py
# 出包编排阶段（pack/orch）单测外壳：python3 tests/orch_stages_test.py（22 例，本机约 8 秒；缺 .NET 的两例自己跳过，不下载）
# 11-06 合入运维线：原 .py 文件头「门禁手动」（W1 只在 Windows / Mac 显式跑），手动期间 10b9156f3（addr_need.py 顶层 import nso_plain）、
#   27d3445c1（stages 选表加载 pack/pkg_srcs.py）改了单测镜像的依赖没人发现，main 上 8 例红。改由本外壳接进门禁
set -u
cd "$(dirname "$0")/.." || exit 1
exec "${S2A_PY:-python3}" -B tests/orch_stages_test.py
