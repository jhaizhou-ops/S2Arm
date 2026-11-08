#!/usr/bin/env bash
# W6.0 GPU 时间戳设备探针：验证真实队列的 timestampValidBits/period，以及
# “按帧奇偶双查询池、下一帧 arm 另一池后再读上一帧”的读法；同时打印单池
# 在下一帧 reset 后被覆盖的反例。不启动游戏、不读游戏资源。
#
# 用法：bash android/tools/vk_timestamp_probe.sh
# 环境：ANDROID_NDK_HOME / S2A_ADB（不设则取第一台 device）
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
. "$(dirname "$0")/ndk_toolchain.sh"
ndk=$(s2a_ndk_resolve) || { echo "no NDK; timestamp probe NOT RUN" >&2; exit 2; }
serial=${S2A_ADB:-$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')}
[ -n "$serial" ] || { echo "no adb device; timestamp probe NOT RUN" >&2; exit 2; }
cc=$(s2a_ndk_clang "$ndk" 29) || { echo "no NDK clang; timestamp probe NOT RUN" >&2; exit 2; }
out=$(mktemp -d "${TMPDIR:-/tmp}/s2a-vk-ts.XXXXXX")
trap 'rm -rf "$out"' EXIT
"$cc" -std=c11 -O2 -Wall -Wextra -Werror -Wno-missing-field-initializers \
    -o "$out/vk_timestamp_probe" "$repo/android/tests/vk_timestamp_probe.c" -lvulkan
adb -s "$serial" push "$out/vk_timestamp_probe" /data/local/tmp/vk_timestamp_probe >/dev/null
adb -s "$serial" shell chmod 755 /data/local/tmp/vk_timestamp_probe
echo "device: $serial $(adb -s "$serial" shell getprop ro.product.model | tr -d '\r') / Android $(adb -s "$serial" shell getprop ro.build.version.release | tr -d '\r')"
adb -s "$serial" shell /data/local/tmp/vk_timestamp_probe
