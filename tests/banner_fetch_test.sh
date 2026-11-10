#!/bin/bash
# 门禁覆盖：pack/banner_fetch.py tests/test_banner_fetch.py
# 出包期横版封面抓取单测（#101；urlopen 全打桩、不联网，约 1 秒）：bash tests/banner_fetch_test.sh
cd "$(dirname "$0")/.." || exit 1
"${S2A_PY:-python3}" -B -m unittest tests/test_banner_fetch.py
