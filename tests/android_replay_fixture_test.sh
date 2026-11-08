#!/usr/bin/env bash
# 门禁只看：android/tests/replay_fixture/* android/CMakeLists.txt graphics/nvn/gfx/nvn/nvn_backend.h graphics/nvn/gfx/nvn/nvn_obj.h graphics/nvn/gfx/nvn/nvn_tex.h graphics/nvn/gfx/nvn/nvn_refl.h graphics/nvn/gfx/nvn/include/*
# NVN 回放夹具（android/tests/replay_fixture/run_test.sh）：S2RF 容器读写 / 零容差字节比对 /
# 7 对合成样例（.in/.exp）逐字节复现；宿主 CPU-only，约 10 秒，不碰 GPU / 真机（#784 D27）
set -euo pipefail
H=$(cd "$(dirname "$0")/.." && pwd)
exec bash "$H/android/tests/replay_fixture/run_test.sh"
