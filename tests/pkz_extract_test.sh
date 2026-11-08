#!/bin/bash
# PKZ / DAT 的合成容器回归；不读游戏、不联网，不改运行时。
# 门禁覆盖：graphics/tools/shbake/pkz.py graphics/tools/shbake/pkz_inventory.py graphics/tools/shbake/nxsh_extract.py graphics/tools/shbake/tests/t_pkz.py
set -eu
cd "$(dirname "$0")/.."
PY=${S2A_PY:-${PY:-$HOME/.s2arm/venv/bin/python3}}   # 钉版解释器（SARC 用 nxfmt，不另装包），与其它工具单测一致
"$PY" -B graphics/tools/shbake/tests/t_pkz.py
