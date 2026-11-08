#!/bin/bash
# Q15 编库缓存跨次保留/容量策略：合成目录与 Jobs 执行锁，不调用 Metal / 游戏 / 设备。
# 门禁覆盖：pack/jobs/cache_retention.py pack/jobs/library.py pack/jobs/ipa.py
set -eu
H=$(cd "$(dirname "$0")/.." && pwd)
exec "${S2A_PY:-$HOME/.s2arm/venv/bin/python3}" -m unittest discover -s "$H/pack/jobs/tests" -p test_cache_retention.py -v
