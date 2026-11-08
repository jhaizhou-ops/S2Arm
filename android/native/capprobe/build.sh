#!/bin/bash
# Build the standalone aarch64 capprobe binary (Android, NDK 29) with the
# SPIR-V shaders embedded, so the device side receives a single file.
# This is the development/manual path: it regenerates capprobe_spv.h from
# shaders/ so header and binary stay in sync. The app build packages the
# same standalone binary via package.sh into jniLibs instead (it uses the
# committed header and does not need glslangValidator).
# Requires glslangValidator on PATH and ANDROID_NDK (defaults to the
# pinned NDK under ~/Library/Android/sdk).
set -eu
cd "$(dirname "$0")"
NDK=${ANDROID_NDK:-${ANDROID_NDK_ROOT:-$HOME/Library/Android/sdk/ndk/29.0.14206865}}
HOST_TAG=${NDK_HOST_TAG:-darwin-x86_64}
API=${CAPPROBE_API:-29}
CC="$NDK/toolchains/llvm/prebuilt/$HOST_TAG/bin/aarch64-linux-android${API}-clang"
GLSLANG=${GLSLANG:-glslangValidator}
out=${OUT:-build}
mkdir -p "$out/spv"
for s in vert geom frag tesc tese; do
    "$GLSLANG" -V --target-env vulkan1.1 "shaders/capprobe.$s" -o "$out/spv/capprobe.$s.spv"
done
hdr="$out/capprobe_spv.h"
# capprobe.c uses a quote include, so the committed header beside it wins over
# any -I path in both this standalone build and the in-library game build —
# regenerate it in place to keep shader and binary in sync.
committed="capprobe_spv.h"
: > "$hdr"
for s in vert geom frag tesc tese; do
    name="capprobe_$s"
    echo "static const unsigned char ${name}[] __attribute__((aligned(4))) = {" >> "$hdr"
    xxd -i < "$out/spv/capprobe.$s.spv" >> "$hdr"
    echo "};" >> "$hdr"
    echo "#define ${name}_len ((unsigned int)sizeof(${name}))" >> "$hdr"
done
cp "$hdr" "$committed"
"$CC" -std=c11 -O2 -Wall -Wextra -Werror -I"$out" -DS2A_CAPPROBE_STANDALONE \
    capprobe.c -lvulkan -o "$out/capprobe"
echo "built $out/capprobe"
