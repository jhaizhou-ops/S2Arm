#!/bin/bash
# Metal 编译耗时剖析（tools/metal_compile_prof.py + tests/metal_prof/gen_fixtures.py）单测：MSL 顶层切分 / 删函数体 /
#   语句块切分 / 夹具段切分（纯解析，秒级）；本机有 metal 时再跑 measure / sections / bisect 端到端并核输入未被改。
# 门禁覆盖：tools/metal_compile_prof.py tests/metal_prof/gen_fixtures.py
set -u; H=$(cd "$(dirname "$0")/.." && pwd)
exec python3 "$H/tests/metal_prof_test.py"
