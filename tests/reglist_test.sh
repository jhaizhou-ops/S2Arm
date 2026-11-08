#!/bin/bash
# 登记表按款拆目录（tools/reglist.py）单测 + 真数据结构校验
# 门禁覆盖：tools/reglist.py docs/名单_能力强信号/* docs/名单_60帧能力覆盖/* docs/名单_60帧/* docs/名单_满屏比例/* docs/名单_直连实测/* docs/名单_直连缺陷上游/*
set -eu
R=$(cd "$(dirname "$0")/.." && pwd)
exec "${S2A_PY:-python3}" "$R/tests/reglist_test.py" "$@"
