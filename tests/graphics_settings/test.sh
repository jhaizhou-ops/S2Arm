#!/bin/bash
# 门禁手动：要私有游戏数据：要传一张真实游戏帧 PNG
# 真实游戏帧 → 系统菜单全部组合 → C#设置入口 → Metal后处理 / 上屏缩放。
# tests/graphics_settings/test.sh <游戏帧.png> [输出目录]
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${2:-$R/build/graphics-settings}
mkdir -p "$OUT"
python3 "$R/tests/graphics_settings/image.py" "${1:?提供真实游戏帧 PNG}" "$OUT"
make -C "$R/graphics/metal" "$R/build/gal/libnxgal.dylib" "$R/build/gal/gal_helpers/.stamp"
export NXGAL_LIB=$R/build/gal/libnxgal.dylib
PROJECT=$R/tests/graphics_settings/GraphicsSettingsTest.csproj
ARTIFACTS=$R/build/graphics-settings-dotnet
dotnet build "$PROJECT" -c Release --artifacts-path "$ARTIFACTS"
dotnet run --project "$PROJECT" -c Release --artifacts-path "$ARTIFACTS" --no-build -- "$OUT/input.json" "$OUT"
python3 - "$OUT" <<'PY'
import json
import pathlib
import sys
from PIL import Image
out = pathlib.Path(sys.argv[1])
manifest = json.loads((out / "input.json").read_text())
for mode in manifest["aa"]:
    raw = (out / f"{mode}.bgra").read_bytes()
    Image.frombytes("RGBA", (manifest["width"], manifest["height"]), raw, "raw", "BGRA").save(out / f"{mode}.png")
PY
