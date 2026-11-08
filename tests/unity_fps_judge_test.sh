#!/bin/bash
# Unity 交换间隔判定（tools/unity_fps_judge.py）合成夹具单测：够 / 不够 / 判不出；不需要游戏/元数据原件。
# 门禁覆盖：tools/unity_fps_judge.py（同时覆盖 tools/il2cpp_fps_loc.py 的结构定位）
set -eu
H=$(cd "$(dirname "$0")/.." && pwd)
"${S2A_PY:-python3}" "$H/tests/unity_fps_judge_test.py"
"${S2A_PY:-python3}" "$H/tests/unity_fps_judge_v24_v31_test.py"
