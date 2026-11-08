#!/bin/bash
# 门禁覆盖：graphics/tools/shbake/nxsh_extract.py tests/nxsh_crilayla_race_test.py
# 抽取进程并发首次编 libcrilayla（Windows 上已加载的库不能被替换，11-06 天眼女神异闻录5）：替身单测，约 1 秒；见 tests/nxsh_crilayla_race_test.py
set -eu
cd "$(dirname "$0")/.." && python3 tests/nxsh_crilayla_race_test.py
