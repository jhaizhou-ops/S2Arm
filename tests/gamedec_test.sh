#!/bin/bash
# 门禁覆盖：pack/gamedec/Guest.cs pack/gamedec/Locate.cs pack/gamedec/Nso.cs pack/gamedec/Program.cs pack/gamedec/gamedec.csproj
# 游戏自带解码器的跨平台工具模式（ARMeilleure 执行游戏 main 里的解码函数）：手写最小 NSO 夹具，接管 main 自带 malloc、导入 memcpy、服务模式收尾退出、DT_RELR 重定位；见 tests/gamedec_test.py
set -eu
R=$(cd "$(dirname "$0")/.." && pwd)
PY=${S2A_PYTHON:-${S2A_PY:-python3}}
cd "$R" && PYTHONUTF8=1 "$PY" tests/gamedec_test.py
