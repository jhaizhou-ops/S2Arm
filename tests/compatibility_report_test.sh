#!/usr/bin/env bash
# 门禁覆盖：tools/compatibility_report.py tests/compatibility_report_test.py docs/名单_60帧/* docs/名单_60帧能力覆盖/* docs/名单_满屏比例/* docs/名单_直连实测/* graphics/widen/tables/verified.tsv docs/研究/直连泛化普查.md docs/方案_联机LDN.md pack/oneclick/titles.tsv pack/display_names.tsv docs/能力原因_玩家文案.tsv docs/发布验收.tsv docs/兼容性清单.md
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
python3 "$ROOT/tests/compatibility_report_test.py"
