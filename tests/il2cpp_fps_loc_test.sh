#!/bin/bash
# IL2CPP v29 只读方法入口定位：原创合成正负控；不需要游戏/元数据原件。
# 门禁覆盖：tools/il2cpp_fps_loc.py
set -eu
H=$(cd "$(dirname "$0")/.." && pwd)
exec "${S2A_PY:-python3}" "$H/tests/il2cpp_fps_loc_test.py"
