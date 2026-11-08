#!/usr/bin/env bash
# C0 检查：同一份 ABI 头在主机 C、托管 C#、ARM64（可选真机）编译/运行并逐字段对拍。
# 无设备也跑前两项；有 NDK 就编 ARM64，有 adb 设备就真机执行（否则明确标未跑，不算通过）。
# 用法：bash android/tools/direct_abi_check.sh
# 环境：ANDROID_NDK_HOME / ANDROID_NDK / S2A_ADB（可选，默认第一台设备）
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
out=${TMPDIR:-/tmp}/s2a-direct-abi-$$
mkdir -p "$out"
trap 'rm -rf "$out"' EXIT

cc=${CC:-cc}
echo "== host C =="
"$cc" -std=c11 -O2 -Wall -Wextra -Werror -I"$repo" -I"$repo/runtime/include" \
    -o "$out/c" "$repo/android/tests/direct_abi_test.c" \
    "$repo/android/native/direct/s2a_direct_abi.c"
"$out/c" > "$out/c.json"
tail -1 "$out/c.json"

echo "== managed C# =="
(cd "$repo/android/core-runtime/direct-abi-tests" && dotnet run -c Release --no-restore 2>/dev/null || dotnet run -c Release) > "$out/cs.log"
grep -m1 '^{' "$out/cs.log" > "$out/cs.json"
grep 'direct-abi-cs: ok' "$out/cs.log"

arm64_args=()
. "$(dirname "$0")/ndk_toolchain.sh"
ndk=$(s2a_ndk_resolve || true)
if [ -n "$ndk" ] && [ -d "$ndk" ]; then
    echo "== arm64 probe (NDK $(cat "$ndk/source.properties" | tr -d '\r' | sed -n 's/^Pkg.Revision = //p')) =="
    compile=$(s2a_ndk_clang "$ndk" 29) || { echo "no NDK clang for this host" >&2; exit 2; }
    "$compile" -std=c11 -O2 -Wall -Wextra -Werror -I"$repo" -I"$repo/runtime/include" \
        -o "$out/arm64" "$repo/android/tests/direct_abi_test.c" \
        "$repo/android/native/direct/s2a_direct_abi.c"
    serial=${S2A_ADB:-$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')}
    if [ -n "$serial" ]; then
        adb -s "$serial" push "$out/arm64" /data/local/tmp/direct_abi_test >/dev/null
        adb -s "$serial" shell chmod 755 /data/local/tmp/direct_abi_test
        adb -s "$serial" shell /data/local/tmp/direct_abi_test > "$out/arm64.log"
        grep -m1 '^{' "$out/arm64.log" > "$out/arm64.json"
        grep 'direct-abi: ok' "$out/arm64.log"
        echo "device: $serial ($(adb -s "$serial" shell getprop ro.product.model | tr -d '\r') / $(adb -s "$serial" shell getprop ro.build.version.release | tr -d '\r'))"
        arm64_args=(--arm64 "$out/arm64.json")
    else
        echo "arm64: compiled but NOT RUN (no adb device); this check is incomplete"
    fi
else
    echo "arm64: NOT RUN (no NDK); this check is incomplete"
fi

python3 "$repo/android/tests/direct_abi_compare.py" \
    --c "$out/c.json" --cs "$out/cs.json" "${arm64_args[@]}"
