#!/usr/bin/env bash
# 新 Vulkan 后端第一片：C2 编译输出 → nvn_vk_be → 画全屏三角形 → 读回。
# 不经过 d2r 引擎、不读 .xgs；失败明确报红。用法：bash android/tools/nvn_vk_be_probe.sh
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
. "$(dirname "$0")/ndk_toolchain.sh"
ndk=$(s2a_ndk_resolve) || { echo "no NDK; nvn_vk_be probe NOT RUN" >&2; exit 2; }
serial=${S2A_ADB:-$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')}
[ -n "$serial" ] || { echo "no adb device; nvn_vk_be probe NOT RUN" >&2; exit 2; }
command -v dotnet >/dev/null || { echo "no dotnet; nvn_vk_be probe NOT RUN" >&2; exit 2; }
cc=$(s2a_ndk_clang "$ndk" 29) || { echo "no NDK clang; probe NOT RUN" >&2; exit 2; }
out=$(mktemp -d "${TMPDIR:-/tmp}/s2a-nvn-vk-be.XXXXXX")
trap 'rm -rf "$out"' EXIT

(cd "$repo/graphics/tools/direct/tests/compiler" && dotnet run -c Release -- --emit-requests "$out/c2req") >/dev/null
for req in c2vspos c2tex c2ubo; do
    dotnet run -c Release --project "$repo/graphics/tools/direct/compiler/cli" -- \
        compile --request "$out/c2req/$req.json" --output "$out/prog-$req" >/dev/null
    python3 "$repo/android/tools/nvn_vk_program_blob.py" "$out/prog-$req/program.json" "$out/$req.blob" >/dev/null
done

"$cc" -std=c11 -O2 -Wall -Wextra -Werror -Wno-missing-field-initializers -Wno-nonnull \
    -I "$repo/android/native/direct" -I "$repo/android/native/nvn" -I "$repo/graphics/nvn/gfx/nvn" -I "$repo/graphics/nvn/gfx/nvn/include" -I "$repo/graphics/nvn/gfx/tex" \
    -o "$out/nvn_vk_be_probe" "$repo/android/tests/nvn_vk_be_probe.c" \
    "$repo/android/native/direct/vk_device.c" "$repo/android/native/nvn/nvn_vk_format.c" "$repo/android/native/nvn/nvn_vk_texcache.c" "$repo/android/native/nvn/nvn_vk_bcdec.c" "$repo/graphics/nvn/gfx/nvn/nvn_tex.c" "$repo/graphics/nvn/gfx/tex/nvn_deswizzle.c" -lvulkan -llog -lm
python3 - "$out" <<'PYTEX'
import struct, sys
out = sys.argv[1]
def tex(path, fmt, w, h, data):
    with open(path, 'wb') as f:
        f.write(b'NVNT' + struct.pack('<IIII', fmt, w, h, len(data)) + data)
tex(out + '/green_rgba8.tex', 0x25, 4, 4, bytes([0, 255, 0, 255]) * 16)
tex(out + '/green_rgb565.tex', 0x3c, 4, 4, struct.pack('<16H', *([0x07E0] * 16)))
PYTEX

adb -s "$serial" shell mkdir -p /data/local/tmp/s2a-nvn-vk-be
adb -s "$serial" push "$out/nvn_vk_be_probe" "$out/c2vspos.blob" "$out/c2tex.blob" "$out/c2ubo.blob" "$out/green_rgba8.tex" "$out/green_rgb565.tex" /data/local/tmp/s2a-nvn-vk-be/ >/dev/null
adb -s "$serial" shell chmod 755 /data/local/tmp/s2a-nvn-vk-be/nvn_vk_be_probe
echo "device: $serial $(adb -s "$serial" shell getprop ro.product.model | tr -d '\r') / Android $(adb -s "$serial" shell getprop ro.build.version.release | tr -d '\r')"
adb -s "$serial" shell /data/local/tmp/s2a-nvn-vk-be/nvn_vk_be_probe /data/local/tmp/s2a-nvn-vk-be/c2vspos.blob
adb -s "$serial" shell /data/local/tmp/s2a-nvn-vk-be/nvn_vk_be_probe /data/local/tmp/s2a-nvn-vk-be/c2tex.blob /data/local/tmp/s2a-nvn-vk-be/green_rgba8.tex
adb -s "$serial" shell /data/local/tmp/s2a-nvn-vk-be/nvn_vk_be_probe /data/local/tmp/s2a-nvn-vk-be/c2tex.blob /data/local/tmp/s2a-nvn-vk-be/green_rgb565.tex
adb -s "$serial" shell /data/local/tmp/s2a-nvn-vk-be/nvn_vk_be_probe /data/local/tmp/s2a-nvn-vk-be/c2ubo.blob
