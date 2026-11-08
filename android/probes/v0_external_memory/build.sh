#!/usr/bin/env bash
# Cross-compile the WP17 V0 probe to an arm64 Android executable inside the pinned Android build
# image (NDK 29.0.14206865, API 35). Output: build/android-probes/v0_external_memory/v0probe
#
#   bash android/probes/v0_external_memory/build.sh
#
# S2A_ANDROID_IMAGE overrides the image (default: the s2arm-android-build:1 digest below).
set -euo pipefail
probe_dir=$(cd "$(dirname "$0")" && pwd)
repo_dir=$(cd "$probe_dir/../../.." && pwd)
image=${S2A_ANDROID_IMAGE:-sha256:4cbb20d3398c3a28eb95c07bf99352834bb622951426976ca8438a7fb2498321}
rel=android/probes/v0_external_memory
out_rel=build/android-probes/v0_external_memory
rev=$(git -C "$repo_dir" rev-parse --short=12 HEAD 2> /dev/null || echo unknown)
if [ -n "$(git -C "$repo_dir" status --porcelain -- "$rel" 2> /dev/null)" ]; then rev="$rev-dirty"; fi
mkdir -p "$repo_dir/$out_rel"

docker run --rm --platform linux/amd64 -v "$repo_dir:/src" -w /src "$image" bash -euo pipefail -c "
ndk=/opt/android-sdk/ndk/29.0.14206865
tc=\$ndk/toolchains/llvm/prebuilt/linux-x86_64/bin
\$ndk/shader-tools/linux-x86_64/glslc --target-env=vulkan1.1 -mfmt=c -o $out_rel/xor.comp.inc $rel/xor.comp
\$ndk/shader-tools/linux-x86_64/glslc --target-env=vulkan1.1 -o $out_rel/xor.spv $rel/xor.comp
\$ndk/shader-tools/linux-x86_64/spirv-val --target-env vulkan1.1 $out_rel/xor.spv
\$tc/aarch64-linux-android35-clang -std=c11 -O2 -Wall -Wextra -Werror -fPIE -pie \
    -DPROBE_REV='\"$rev\"' -I$out_rel -o $out_rel/v0probe $rel/v0probe.c -lvulkan -landroid
\$tc/llvm-strip $out_rel/v0probe
\$tc/llvm-readelf -d $out_rel/v0probe | grep NEEDED
"
shasum -a 256 "$repo_dir/$out_rel/v0probe"
