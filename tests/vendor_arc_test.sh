#!/bin/bash
# 厂商着色器容器（Telltale ttarch2 / Volition VPP / 主程序内嵌字典的 zstd 帧，11-02 着色器容器族 A 组）的合成夹具回归；不读游戏、不联网，不改运行时。
# 门禁覆盖：graphics/tools/shbake/telltale.py graphics/tools/shbake/volition_vpp.py graphics/tools/shbake/nso_zstd.py graphics/tools/shbake/nxsh_extract.py graphics/tools/shbake/tests/t_vendor_arc.py
set -eu
cd "$(dirname "$0")/.."
PY=${S2A_PY:-${PY:-$HOME/.s2arm/venv/bin/python3}}   # 钉版解释器（3.14：夹具用标准库 compression.zstd 造带号字典）
"$PY" -B graphics/tools/shbake/tests/t_vendor_arc.py
