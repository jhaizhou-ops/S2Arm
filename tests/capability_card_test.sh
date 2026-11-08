#!/usr/bin/env bash
# 门禁覆盖：tools/compatibility_report.py tests/capability_card_test.py docs/能力卡_数据口径.md docs/名单_60帧/* docs/名单_60帧能力覆盖/* docs/名单_满屏比例/* docs/名单_直连实测/* graphics/widen/tables/verified.tsv runtime/fps/*
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
python3 "$ROOT/tests/capability_card_test.py"
