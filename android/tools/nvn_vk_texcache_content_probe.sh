#!/usr/bin/env bash
# 批 A 的 A 级证据（Adreno 真机）：把同一份内容交接用例拿到设备上跑，字节结果必须与 lavapipe（S 级）一致：
#   ① GPU 清红 → CPU 整图写蓝 → Draw/ReadTexels 蓝；② 局部写蓝 → 蓝块+红底；③ 内容 7→11 两次 draw 各看各的；
#   ④ 读回不写回 guest；⑤ 1 MiB 保护块诱饵字节不误判；⑥ 提交失败注入 fail-closed；⑦ 账本不可用 fail-closed；
#   ⑧ 全 CPU 内容在途 → 退役+新建。
#
# 只编生产实现 + 同一份用例源码，不改任何行为；不依赖游戏包/会话，直接在设备上建 Vulkan 设备跑。
# 无设备时退 2（不静默跳过）；设备 Vulkan 不可用/用例红则原样退非 0 并把诊断打回本地。
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
android="$repo/android"
. "$(dirname "$0")/ndk_toolchain.sh"
ndk=$(s2a_ndk_resolve) || { echo "【红】没有 NDK：A 级探针不跑（不静默跳过）" >&2; exit 2; }
serial=${S2A_ADB:-$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')}
[ -n "$serial" ] || { echo "【红】没有 adb 设备：A 级探针不跑（不静默跳过）" >&2; exit 2; }
cc=$(s2a_ndk_clang "$ndk" 29) || { echo "【红】没有 NDK clang：A 级探针不跑" >&2; exit 2; }
out=$(mktemp -d "${TMPDIR:-/tmp}/s2a-nvn-content-probe.XXXXXX")
trap 'rm -rf "$out"' EXIT
"$cc" -std=c11 -O2 -Wall -Wextra -Werror -Wno-missing-field-initializers -Wno-nonnull \
    -I "$android/native" -I "$android/native/direct" -I "$android/native/nvn" \
    -I "$repo/graphics/nvn/third_party/vulkan-headers/include" \
    -I "$repo/graphics/nvn/gfx/nvn" -I "$repo/graphics/nvn/gfx/nvn/include" -I "$repo/graphics/nvn/gfx/tex" \
    -I "$repo/graphics/nvn" -I "$repo/runtime/include" -I "$repo/runtime/src" \
    -o "$out/content_probe" \
    "$android/tests/nvn_vk_texcache_content_test.c" \
    "$android/native/nvn/nvn_vk_texcache.c" \
    "$android/native/nvn/nvn_vk_readback.c" \
    "$android/native/nvn/nvn_vk_readback_gpu.c" \
    "$android/native/nvn/nvn_vk_readback_plan.c" \
    "$android/native/nvn/nvn_vk_bcdec.c" \
    "$android/native/nvn/nvn_vk_format.c" \
    "$repo/graphics/nvn/gfx/nvn/nvn_tex.c" \
    "$repo/graphics/nvn/gfx/nvn/nvn_dirty.c" \
    "$repo/graphics/nvn/gfx/tex/nvn_deswizzle.c" \
    "$android/native/direct/vk_device.c" \
    -lvulkan -llog -lm -pthread
adb -s "$serial" push "$out/content_probe" /data/local/tmp/nvn_content_probe >/dev/null
adb -s "$serial" shell chmod 755 /data/local/tmp/nvn_content_probe
set +e
adb -s "$serial" shell /data/local/tmp/nvn_content_probe
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
    echo "【红】Adreno 上的内容交接用例失败（rc=${rc}）；逐条见上方 ✗ 行" >&2
    exit "$rc"
fi
echo "nvn-vk-texcache-content-probe(Adreno): A 级字节结果与 S 级一致"
