#!/bin/bash
# 门禁覆盖：ios/macho_dylib.py ios/embed.py pack/ship_ext.py pack/pkg_srcs.py pack/shell_build.sh pack/shell/manifest.py tests/test_ship_ext.py
# 阶段 0 外置镜像包写出器、预编壳组装与多款容器组装单测（约 3 秒）：bash tests/ship_ext_test.sh
cd "$(dirname "$0")/.." || exit 1
"${S2A_PY:-python3}" -B tests/test_ship_ext.py
