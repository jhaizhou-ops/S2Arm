#!/bin/bash
# 能力卡数据口径（docs/能力卡_数据口径.md，#717）的源表形状单测：表在、表头含所述列、枚举取值合法；纯标准库 Python 3。门禁只发现 tests/*_test.sh，这里转给同名 .py
# 门禁覆盖：docs/能力卡_数据口径.md docs/名单_60帧/* docs/名单_60帧能力覆盖/* docs/名单_满屏比例/* graphics/widen/tables/verified.tsv runtime/fps/*
set -eu
R=$(cd "$(dirname "$0")/.." && pwd)
PY=${S2A_PYTHON:-${S2A_PY:-python3}}
cd "$R"
exec "$PY" "$R/tests/cap_card_sources_test.py" "$@"
