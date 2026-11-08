#!/usr/bin/env bash
# 新后端管线缓存：同一个 blaze 复用、不同 blob/格式新建。
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
. "$(dirname "$0")/ndk_toolchain.sh"
ndk=$(s2a_ndk_resolve) || { echo "no NDK; pipeline probe NOT RUN" >&2; exit 2; }
serial=${S2A_ADB:-$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')}
[ -n "$serial" ] || { echo "no adb device; probe NOT RUN" >&2; exit 2; }
command -v dotnet >/dev/null || { echo "no dotnet; probe NOT RUN" >&2; exit 2; }
cc=$(s2a_ndk_clang "$ndk" 29) || { echo "no NDK clang; probe NOT RUN" >&2; exit 2; }
out=$(mktemp -d "${TMPDIR:-/tmp}/s2a-nvn-vk-pipeline.XXXXXX")
trap 'rm -rf "$out"' EXIT
(cd "$repo/graphics/tools/direct/tests/compiler" && dotnet run -c Release -- --emit-requests "$out/c2req") >/dev/null
for req in c2vspos c2tex; do
    dotnet run -c Release --project "$repo/graphics/tools/direct/compiler/cli" -- \
        compile --request "$out/c2req/$req.json" --output "$out/prog-$req" >/dev/null
    python3 "$repo/android/tools/nvn_vk_program_blob.py" "$out/prog-$req/program.json" "$out/$req.blob" >/dev/null
done
"$cc" -std=c11 -O2 -Wall -Wextra -Werror -Wno-missing-field-initializers -Wno-nonnull \
    -I "$repo/android/native/direct" -I "$repo/android/native/nvn" \
    -o "$out/nvn_vk_pipeline_test" "$repo/android/tests/nvn_vk_pipeline_test.c" \
    "$repo/android/native/nvn/nvn_vk_pipeline.c" "$repo/android/native/direct/vk_device.c" -lvulkan -llog -lm
adb -s "$serial" shell mkdir -p /data/local/tmp/s2a-nvn-vk-pipe
adb -s "$serial" push "$out/nvn_vk_pipeline_test" "$out/c2vspos.blob" "$out/c2tex.blob" /data/local/tmp/s2a-nvn-vk-pipe/ >/dev/null
adb -s "$serial" shell chmod 755 /data/local/tmp/s2a-nvn-vk-pipe/nvn_vk_pipeline_test
adb -s "$serial" shell /data/local/tmp/s2a-nvn-vk-pipe/nvn_vk_pipeline_test /data/local/tmp/s2a-nvn-vk-pipe/c2vspos.blob /data/local/tmp/s2a-nvn-vk-pipe/c2tex.blob
