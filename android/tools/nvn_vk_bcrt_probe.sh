#!/usr/bin/env bash
# BC/块压缩纹理作为渲染目标（“块=像素”影子）的 A 级证据（Adreno 真机）：同一份用例源码拿设备上跑，
# 字节结果必须与 lavapipe（S 级，tools/nvn_vk_bcrt_test.sh）一致：3D 深度切片往返、2D 数组 mip 往返、
# 影子直写路径。
#
# 只编生产实现 + 同一份用例源码，不改任何行为；不依赖游戏包/会话，直接在设备上建 Vulkan 设备跑。
# 无设备/无 NDK clang 时退 2（不静默跳过）；设备 Vulkan 不可用或用例红则原样退非 0 并把诊断打回本地。
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
android="$repo/android"
. "$(dirname "$0")/ndk_toolchain.sh"
ndk=$(s2a_ndk_resolve) || { echo "【红】没有 NDK：A 级探针不跑（不静默跳过）" >&2; exit 2; }
command -v adb >/dev/null 2>&1 || { echo "【红】没有 adb：A 级探针不跑（不静默跳过）" >&2; exit 2; }
serial=${S2A_ADB:-$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')}
[ -n "$serial" ] || { echo "【红】没有 adb 设备：A 级探针不跑（不静默跳过）" >&2; exit 2; }
cc=$(s2a_ndk_clang "$ndk" 29) || { echo "【红】没有 NDK clang：A 级探针不跑" >&2; exit 2; }
out=$(mktemp -d "${TMPDIR:-/tmp}/s2a-nvn-bcrt-probe.XXXXXX")
trap 'rm -rf "$out"' EXIT
"$cc" -std=c11 -O2 -Wall -Wextra -Werror -Wno-missing-field-initializers -Wno-nonnull \
    -I "$android/native" -I "$android/native/direct" -I "$android/native/nvn" \
    -I "$repo/graphics/nvn/third_party/vulkan-headers/include" \
    -I "$repo/graphics/nvn/gfx/nvn" -I "$repo/graphics/nvn/gfx/nvn/include" -I "$repo/graphics/nvn/gfx/tex" \
    -I "$repo/graphics/nvn" -I "$repo/runtime/include" -I "$repo/runtime/src" \
    -o "$out/bcrt_probe" \
    "$android/tests/nvn_vk_bcrt_test.c" \
    "$android/native/nvn/nvn_vk_mrt.c" \
    "$android/native/nvn/nvn_vk_format.c" \
    "$android/native/direct/vk_device.c" \
    -lvulkan -llog -lm -pthread
adb -s "$serial" push "$out/bcrt_probe" /data/local/tmp/nvn_bcrt_probe >/dev/null
adb -s "$serial" shell chmod 755 /data/local/tmp/nvn_bcrt_probe
set +e
adb -s "$serial" shell /data/local/tmp/nvn_bcrt_probe
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
    echo "【红】Adreno 上的 bcrt 往返用例失败（rc=${rc}）；逐条见上方 ✗ 行" >&2
    exit "$rc"
fi
echo "nvn-vk-bcrt-probe(Adreno): A 级字节结果与 S 级一致"
