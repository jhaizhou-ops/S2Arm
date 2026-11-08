#!/bin/bash
# Package the standalone capprobe helper into a jniLibs layout for the app
# build (build.gradle capprobeJniLibs task calls this with ANDROID_NDK_HOME
# and OUT set):
#   $OUT/arm64-v8a/libs2a_capprobe.so
#
# AGP packages only shared libraries from CMake targets, so the probe
# executable borrows the lib*.so name in a jniLibs source directory — it
# lands in the APK at lib/arm64-v8a/libs2a_capprobe.so like any packaged
# library, STORED and page-aligned (extractNativeLibs=false). Native runs
# it through the system linker as "<sourceDir>!/lib/arm64-v8a/
# libs2a_capprobe.so" (see capprobe_host.c) — the exec target is
# /system/bin/linker64 and the library maps in place, so nothing leaves
# the package and no extractNativeLibs flip is needed (#1482). The
# committed capprobe_spv.h is used as-is; build.sh owns shader/header
# regeneration during development.
set -eu
cd "$(dirname "$0")"
. ../../tools/ndk_toolchain.sh
ndk=$(s2a_ndk_resolve) || { echo '【红】capprobe package：找不到固定 NDK（ANDROID_NDK_HOME / $ANDROID_HOME/ndk/<固定版本>）' >&2; exit 1; }
api=${CAPPROBE_API:-29}
cc=$(s2a_ndk_clang "$ndk" "$api") || { echo '【红】capprobe package：NDK clang 解析失败' >&2; exit 1; }
out=${OUT:-build/package}
mkdir -p "$out/arm64-v8a"
"$cc" -std=c11 -O2 -Wall -Wextra -Werror -DS2A_CAPPROBE_STANDALONE \
    -Wl,-z,max-page-size=16384 \
    capprobe.c -lvulkan -o "$out/arm64-v8a/libs2a_capprobe.so"
echo "packaged $out/arm64-v8a/libs2a_capprobe.so"
