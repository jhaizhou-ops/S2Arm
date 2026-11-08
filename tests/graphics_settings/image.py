"""使用系统测试环境已有的 Pillow 读取真实游戏帧，生成 Metal 集成测试输入及效果 PNG。"""
import json
import pathlib
import plistlib
import sys

from PIL import Image

root = pathlib.Path(__file__).resolve().parents[2]
source, output = map(pathlib.Path, sys.argv[1:3])
output.mkdir(parents=True, exist_ok=True)
with Image.open(source) as image:
    image = image.convert("RGBA")
    width, height = image.size
    image.putalpha(255)
    pixels = output / "input.bgra"
    pixels.write_bytes(image.tobytes("raw", "BGRA"))
with (root / "ios/Settings.bundle/Root.plist").open("rb") as file:
    specs = {s["Key"]: s for s in plistlib.load(file)["PreferenceSpecifiers"] if "Key" in s}
manifest = {
    "source": str(source.resolve()),
    "width": width,
    "height": height,
    "pixels": str(pixels.resolve()),
    "scales": specs["S2AResolutionScale"]["Values"],
    "aa": specs["S2AAntiAliasing"]["Values"],
    "filters": specs["S2AScalingFilter"]["Values"],
}
(output / "input.json").write_text(json.dumps(manifest, indent=2))
