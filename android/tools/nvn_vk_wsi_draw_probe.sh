#!/usr/bin/env bash
# 新后端：在 WsiProbeActivity 的真实 Surface 上画 C2 程序并 present。
# 需要已安装 per-game APK；包名可用 S2A_PKG 覆盖。
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
serial=${S2A_ADB:-$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')}
[ -n "$serial" ] || { echo "no adb device; wsi draw probe NOT RUN" >&2; exit 2; }
command -v dotnet >/dev/null || { echo "no dotnet; wsi draw probe NOT RUN" >&2; exit 2; }
pkg=${S2A_PKG:-org.s2arm.game.t01001b300b9be000}
out=$(mktemp -d "${TMPDIR:-/tmp}/s2a-nvn-vk-wsi-draw.XXXXXX")
trap 'rm -rf "$out"' EXIT
(cd "$repo/graphics/tools/direct/tests/compiler" && dotnet run -c Release -- --emit-requests "$out/c2req") >/dev/null
dotnet run -c Release --project "$repo/graphics/tools/direct/compiler/cli" -- compile --request "$out/c2req/c2vspos.json" --output "$out/prog" >/dev/null
python3 "$repo/android/tools/nvn_vk_program_blob.py" "$out/prog/program.json" "$out/c2vspos.blob" >/dev/null
blob=/sdcard/Android/data/$pkg/files/wsi.blob
adb -s "$serial" shell mkdir -p "$(dirname "$blob")"
adb -s "$serial" push "$out/c2vspos.blob" "$blob" >/dev/null
adb -s "$serial" shell chmod 666 "$blob"
adb -s "$serial" shell setprop debug.s2a.wsi_blob "$blob"
adb -s "$serial" shell am force-stop "$pkg"
adb -s "$serial" logcat -c
adb -s "$serial" shell am start -W -n "$pkg/org.s2arm.android.WsiProbeActivity" >/dev/null
sleep 6
lines=$(adb -s "$serial" logcat -d 2>/dev/null | grep -E 'nvn-vk draw present' | tail -1)
echo "$lines"
adb -s "$serial" shell "setprop debug.s2a.wsi_blob ''"
echo "$lines" | grep -q 'draw present: 3/3' || { echo "nvn-vk draw present failed" >&2; exit 1; }
echo "nvn-vk wsi draw present: ok"
