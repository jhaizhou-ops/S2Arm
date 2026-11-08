#!/usr/bin/env bash
# C1 ARM64 真机探针：严格 JSON / graphics 描述 / attempt 锁 / 选择事务 / runtime v2。
# 这些测试使用合成 provider 与临时目录，不建 Vulkan device、不跑游戏；GPU 证据另列 C3/C4。
# 用法：bash android/tools/direct_c1_probe.sh
# 环境：ANDROID_NDK_HOME / S2A_ADB（可选，默认第一台设备）
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
. "$(dirname "$0")/ndk_toolchain.sh"
ndk=$(s2a_ndk_resolve) || { echo "no NDK; C1 ARM64 probe NOT RUN" >&2; exit 2; }
cc=$(s2a_ndk_clang "$ndk" 29) || { echo "no NDK clang for this host; C1 ARM64 probe NOT RUN" >&2; exit 2; }
serial=${S2A_ADB:-$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')}
[ -n "$serial" ] || { echo "no adb device; C1 ARM64 probe NOT RUN" >&2; exit 2; }
out=${TMPDIR:-/tmp}/s2a-direct-c1-$$
mkdir -p "$out"
trap 'rm -rf "$out"' EXIT
common=(-std=c11 -O2 -Wall -Wextra -Werror -I "$repo" -I "$repo/runtime/include")
direct="$repo/android/native/direct"

"$cc" "${common[@]}" -o "$out/json" "$repo/android/tests/direct_json_test.c" "$direct/json.c" -lm
"$cc" "${common[@]}" -o "$out/graphics" "$repo/android/tests/direct_graphics_test.c" \
    "$direct/graphics.c" "$direct/json.c" "$direct/sha256.c" "$direct/s2a_direct_abi.c" -lm -llog
"$cc" "${common[@]}" -DS2A_DIRECT_TEST_FAULTS -o "$out/attempt" \
    "$repo/android/tests/direct_attempt_test.c" "$direct/attempt.c" "$direct/json.c" -lm
"$cc" "${common[@]}" -DS2A_DIRECT_TEST_FAULTS -o "$out/selection" \
    "$repo/android/tests/direct_selection_test.c" "$direct/selection.c" "$direct/attempt.c" \
    "$direct/graphics.c" "$direct/json.c" "$direct/sha256.c" "$direct/s2a_direct_abi.c" -lm -llog
"$cc" -std=c11 -O2 -Wall -Wextra -Werror -pthread -I "$repo/android/native" \
    -o "$out/request" "$repo/android/tests/direct_compile_request_test.c" \
    "$direct/compile_request.c" "$direct/compiler_bind.c" "$direct/sha256.c" "$direct/s2a_direct_abi.c"
"$cc" -std=c11 -O2 -Wall -Wextra -Werror -I "$repo/android/native" \
    -I "$repo/graphics/nvn/gfx/nvn/include" -o "$out/texfacts" \
    "$repo/android/tests/direct_texture_facts_test.c" "$direct/texture_facts.c"
"$cc" -std=c11 -O2 -Wall -Wextra -Werror -pthread -I "$repo/android/native" \
    -o "$out/worker" "$repo/android/tests/direct_compile_worker_test.c" "$direct/compile_worker.c"
"$cc" -std=c11 -O2 -Wall -Wextra -Werror -pthread -I "$repo/android/native" \
    -o "$out/sources" "$repo/android/tests/direct_source_store_test.c" \
    "$direct/source_store.c" "$direct/sha256.c"
# F4.3/P1 生产接缝：Draw 快照 → 编译事实/规范身份/P1 备忘键（与宿主同一份实现）
"$cc" -std=c11 -O2 -Wall -Wextra -Werror -Wno-missing-field-initializers -pthread \
    -I "$repo/android/native" -I "$repo/android/native/direct" \
    -I "$repo/android/native/nvn" -I "$repo/graphics/nvn/gfx/nvn" \
    -I "$repo/graphics/nvn/gfx/nvn/include" \
    -o "$out/facts" "$repo/android/tests/direct_nvn_compile_facts_test.c" \
    "$repo/android/native/nvn/nvn_vk_compile_facts.c" \
    "$repo/android/native/nvn/nvn_vk_format.c" \
    "$repo/android/native/nvn/nvn_vk_mrt.c" \
    "$direct/input_identity.c" "$direct/texture_facts.c" "$direct/source_store.c" "$direct/sha256.c"
# §8.5.11 驱动管线缓存：文件层（UUID/版本隔离、损坏拒绝、原子覆盖）
"$cc" -std=c11 -O2 -Wall -Wextra -Werror -D_GNU_SOURCE -pthread \
    -I "$repo/android/native" -I "$repo/android/native/direct" \
    -I "$repo/android/native/nvn" \
    -o "$out/cache" "$repo/android/tests/direct_nvn_driver_cache_test.c" \
    "$repo/android/native/nvn/nvn_vk_driver_cache.c" \
    "$repo/android/native/direct/sha256.c"
# §8.5.11 管线配方：完整规范配方 + 碰撞反例（与宿主同一份实现）
"$cc" -std=c11 -O2 -Wall -Wextra -Werror -Wno-missing-field-initializers -pthread \
    -I "$repo/android/native" -I "$repo/android/native/direct" \
    -I "$repo/android/native/nvn" -I "$repo/graphics/nvn/gfx/nvn" \
    -I "$repo/graphics/nvn/gfx/nvn/include" \
    -o "$out/recipe" "$repo/android/tests/direct_nvn_pipe_recipe_test.c" \
    "$repo/android/native/nvn/nvn_vk_pipe_recipe.c"
"$cc" -std=c11 -O2 -Wall -Wextra -Werror -I "$repo/android/native" \
    -o "$out/diag" "$repo/android/tests/direct_diag_test.c" "$direct/diag.c" "$direct/sha256.c"
"$cc" -std=c11 -O2 -Wall -Wextra -Werror -I "$repo/android/native" \
    -I "$repo/graphics/nvn/gfx/nvn/include" \
    -o "$out/identity" "$repo/android/tests/direct_input_identity_test.c" \
    "$direct/input_identity.c" "$direct/texture_facts.c" "$direct/sha256.c"
"$cc" -std=c11 -O2 -D_GNU_SOURCE -Wall -Wextra -Werror -pthread \
    -I "$repo/android/native" \
    -o "$out/progcache" "$repo/android/tests/direct_program_cache_test.c" \
    "$direct/program_cache.c" "$direct/sha256.c"
"$cc" -std=c11 -O2 -D_GNU_SOURCE -Wall -Wextra -Werror -pthread \
    -I "$repo/runtime/include" -I "$repo/runtime/src" -I "$repo/android/native" \
    -I "$repo/android/native/runtime" \
    -o "$out/runtime" "$repo/android/core-link/runtime-tests/runtime_test.c" \
    "$repo/android/native/runtime/runtime.c" "$repo/runtime/src/guest_main.c" \
    "$direct/selection.c" "$direct/attempt.c" "$direct/graphics.c" "$direct/json.c" \
    "$direct/sha256.c" "$direct/s2a_direct_abi.c" -llog

devdir=/data/local/tmp/s2a-direct-c1-$(basename "$out")
adb -s "$serial" shell mkdir -p "$devdir"
for name in json graphics attempt selection request sources facts cache recipe diag identity texfacts progcache worker runtime; do
    adb -s "$serial" push "$out/$name" "$devdir/$name" >/dev/null
    adb -s "$serial" shell chmod 755 "$devdir/$name"
done
echo "device: $serial $(adb -s "$serial" shell getprop ro.product.model | tr -d '\r') / Android $(adb -s "$serial" shell getprop ro.build.version.release | tr -d '\r')"
echo "NDK: $(sed -n 's/^Pkg.Revision = //p' "$ndk/source.properties" | tr -d '\r')"

run() {
    local name=$1; shift
    local command="TMPDIR=$devdir $devdir/$name $*"
    local result
    result=$(adb -s "$serial" shell "$command" 2>&1)
    echo "$result" | tail -1
    echo "$result" | grep -q "ok\|PASS" || { echo "FAILED: $name $*"; echo "$result"; exit 1; }
}
run json
run graphics
run attempt
run selection
run request
run sources
run facts
run cache
run recipe
run diag
run identity
run texfacts
run progcache
run worker
for mode in v2-invalid v2-generic v2-direct v2-direct-manual v2-leftover \
            v2-frontend-missing v2-manual-direct-no-descriptor v2-bad-descriptor v2-manual-bad-descriptor; do
    run runtime "$mode"
done
echo "direct C1 ARM64 probe: ok"
