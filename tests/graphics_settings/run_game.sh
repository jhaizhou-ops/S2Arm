#!/bin/bash
# 门禁手动：要私有游戏数据：模块目录 + 资源包目录（还要传本局输出 / 倍率 / 抗锯齿）
# 用本工作树已构建的真实宿主验证分辨率；资源只读，存档、缓存和录像均写到本局目录。
# run_game.sh <模块目录> <资源包目录> <本局输出> <倍率> <抗锯齿> [帧率上限] [屏幕宽]
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
MODS=${1:?模块目录}
DATA=${2:?资源包目录}
OUT=${3:?本局输出目录}
export S2A_RES_SCALE=${4:?倍率} S2A_ANTI_ALIASING=${5:?抗锯齿}
export S2A_GFX=generic   # 测的是通用渲染器的分辨率 / 抗锯齿（还录 GAL）；10-25 起不写就走直连
export S2A_FPS=${6:-0} S2A_SCREEN_W=${7:-1920}
mkdir -p "$OUT/Documents" "$OUT/ryu" "$OUT/metal" "$OUT/macro"
export S2A_GAME_DATA=$DATA S2A_RYU_DATA=$OUT/ryu S2A_DOCS=$OUT/Documents
export NXGAL_SHADER_CACHE_DIR=$OUT/metal S2A_MACRO_DUMP=$OUT/macro
export S2A_FRAMES_TSV=$OUT/frames.tsv S2A_AUTOPLAY_OUT=$OUT
export S2A_GALREC=$OUT/galrec S2A_GALREC_FRAMES=60-62
export NXGAL_FRAME_CAP=60-62 NXGAL_FRAME_CAP_OUT=$OUT/framecap.bin
export S2A_RUN_S=${S2A_SETTINGS_RUN_SECONDS:-20}
shasum -a 256 "$R/build/s2arm-host" > "$OUT/host.sha256"
timeout "$((S2A_RUN_S + 30))" "$R/build/s2arm-host" "$MODS" > "$OUT/host.log" 2>&1
test -s "$OUT/framecap.bin"
python3 - "$OUT" <<'PY'
import pathlib
import struct
import sys
from PIL import Image
out = pathlib.Path(sys.argv[1])
with (out / "framecap.bin").open("rb") as file:
    count = 0
    while header := file.read(12):
        frame, width, height = struct.unpack("<III", header)
        pixels = file.read(width * height)
        if len(pixels) != width * height:
            raise ValueError("存帧记录不完整")
        Image.frombytes("L", (width, height), pixels).save(out / f"frame-{frame}-{width}x{height}.png")
        print(f"真实游戏第 {frame} 帧：{width}x{height}")
        count += 1
    if count != 3:
        raise ValueError(f"期望3帧，实际{count}")
PY
