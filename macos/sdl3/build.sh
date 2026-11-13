#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# Private Mac Joy-Con backend. Explicit --fetch prepares the fixed upstream
# source; normal host/test builds never download dependencies.
set -euo pipefail
REV=5403934fd30e3568b1e20f652d4823c796739722
SHA=d0a8bb138c83c77c0241630159c8bf90d2a9f05ae9bbaca5f19574dac88a8e80
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
source "$ROOT/android/tools/fetch_source.sh"
NAME=SDL-$REV.tar.gz
TGZ=$(s2a_source_cache_dir)/$SHA/$NAME
case ${1:-} in
  --fetch)
    s2a_source_fetch "$NAME" "https://github.com/libsdl-org/SDL/archive/$REV.tar.gz" "$SHA"
    exit 0 ;;
  --check-source|'') ;;
  *) echo "Usage: bash macos/sdl3/build.sh [--fetch|--check-source]" >&2; exit 2 ;;
esac
if [ ! -f "$TGZ" ] || [ "$(_s2a_fetch_sha256 "$TGZ")" != "$SHA" ]; then
  echo '🔴 SDL3：固定源码未准备好；请先显式运行 bash macos/sdl3/build.sh --fetch（构建和测试不自动联网）' >&2
  exit 1
fi
[ "${1:-}" != --check-source ] || { echo "$TGZ"; exit 0; }
[ "$(uname -s)" = Darwin ] || { echo '🔴 SDL3：此组件只在 Mac 宿主中构建' >&2; exit 1; }
for tool in cmake ninja; do command -v "$tool" >/dev/null || { echo "🔴 SDL3：需要 $tool（brew install cmake ninja）" >&2; exit 1; }; done
MIN=$(sed -n 's/^MACOSX_DEPLOYMENT_TARGET=//p' "$ROOT/tools/toolchain.env")
[ -n "$MIN" ] || { echo '🔴 SDL3：工具链未声明 macOS 部署下限' >&2; exit 1; }
SDK=$(xcrun --sdk macosx --show-sdk-path)
CC=$(xcrun --sdk macosx --find clang)
CXX=$(xcrun --sdk macosx --find clang++)
KEY=$( { cat "$0"; printf '%s\n' "$MIN"; "$CC" --version; xcrun --sdk macosx --show-sdk-version; } | shasum -a 256 | cut -c1-16)
CACHE=${S2A_SDL_CACHE:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/cache/sdl3}
OUT=$CACHE/osx-arm64-$KEY
LIB=$OUT/libSDL3.dylib
mkdir -p "$CACHE"
if [ ! -s "$LIB" ]; then
  until mkdir "$OUT.lock" 2>/dev/null; do
    pid=$(cat "$OUT.lock/pid" 2>/dev/null || true)
    [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null && rm -rf "$OUT.lock"
    sleep .5
  done
  echo $$ > "$OUT.lock/pid"
  trap 'rm -rf "$OUT.lock"' EXIT
  if [ ! -s "$LIB" ]; then
    W=$OUT.tmp
    rm -rf "$W"; mkdir -p "$W/src" "$W/out"
    tar xzf "$TGZ" -C "$W/src" --strip-components 1
    source "$ROOT/tools/nospace.sh"; WN=$(s2a_nospace "$W")
    cmake -S "$WN/src" -B "$WN/build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" -DCMAKE_OSX_SYSROOT="$SDK" \
      -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN" \
      -DSDL_REVISION="SDL-3.5.0-${REV:0:7}" \
      -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TESTS=OFF -DSDL_TEST_LIBRARY=OFF \
      -DSDL_EXAMPLES=OFF -DSDL_INSTALL=OFF > "$W/configure.log" 2>&1 \
      && cmake --build "$WN/build" -j "${S2A_JOBS:-4}" > "$W/build.log" 2>&1 \
      || { echo "🔴 SDL3：构建失败（$W/configure.log、$W/build.log）" >&2; exit 1; }
    cp -L "$W/build/libSDL3.dylib" "$W/out/libSDL3.dylib"
    install_name_tool -id @executable_path/libSDL3.dylib "$W/out/libSDL3.dylib"
    codesign --force --sign - "$W/out/libSDL3.dylib" >/dev/null 2>&1
    cp "$W/src/LICENSE.txt" "$W/out/LICENSE.txt"
    printf 'revision=%s\nsource_sha256=%s\n' "$REV" "$SHA" > "$W/out/build.txt"
    rm -rf "$OUT"; mv "$W/out" "$OUT"; rm -rf "$W"
  fi
fi
printf '%s\n' "$LIB"
