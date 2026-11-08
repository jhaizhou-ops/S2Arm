#!/usr/bin/env bash
# C2：设备上调用 NativeAOT s2a_direct_compile_v1，与离线 CLI 结果逐字节比对。
# 前提：已安装带 selftest 的 APK（org.s2arm.android），asset direct-compile-request.json 存在。
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
serial=${S2A_ADB:-$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')}
[ -n "$serial" ] || { echo "no adb device; C2 AOT probe NOT RUN" >&2; exit 2; }
adb -s "$serial" logcat -c
adb -s "$serial" shell am force-stop org.s2arm.android
adb -s "$serial" shell am start -W -n org.s2arm.android/.MainActivity --ez s2arm.direct_compile_selftest true >/dev/null
sleep 4
line=$(adb -s "$serial" logcat -d 2>/dev/null | grep -F "direct compile selftest:" | tail -1)
[ -n "$line" ] || { echo "no device compile result in logcat" >&2; exit 1; }
device_sha=$(printf '%s\n' "$line" | sed -n 's/.*sha256=\([0-9a-f]\{64\}\).*/\1/p')
device_bytes=$(printf '%s\n' "$line" | sed -n 's/.*bytes=\([0-9]*\).*/\1/p')
[ -n "$device_sha" ] || { echo "cannot parse device result: $line" >&2; exit 1; }
root=$(mktemp -d "${TMPDIR:-/tmp}/s2a-aot.XXXXXX")
out="$root/result"
trap 'rm -rf "$root"' EXIT
dotnet run -c Release --project "$repo/graphics/tools/direct/compiler/cli" -- \
    compile --request "$repo/android/app/src/main/assets/direct-compile-request.json" --output "$out" >/dev/null
# BSD/macOS：wc -c 会带前导空格、也没有 sha256sum（用 shasum -a 256 兜底），否则这里会假失败。
if command -v sha256sum >/dev/null 2>&1; then
    host_sha=$(sha256sum "$out/program.json" | awk '{print $1}')
else
    host_sha=$(shasum -a 256 "$out/program.json" | awk '{print $1}')
fi
host_bytes=$(wc -c < "$out/program.json" | tr -d ' ')
echo "device: $device_bytes B sha256=$device_sha"
echo "host:   $host_bytes B sha256=$host_sha"
[ "$device_sha" = "$host_sha" ] && [ "$device_bytes" = "$host_bytes" ] || { echo "AOT/offline result differs" >&2; exit 1; }
echo "direct AOT compile: byte-identical ($device_bytes B)"
