#!/bin/bash
# Existing macOS C toolchain + system frameworks only; no package manager.
set -euo pipefail
if [ "$#" -ne 1 ]; then echo "usage: bash tools/direct_compare/build.sh <build-directory>" >&2; exit 2; fi
[ "$(uname -s)" = Darwin ] || { echo "requires macOS ImageIO/CoreGraphics" >&2; exit 2; }
SOURCE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$1"
BUILD=$(cd "$1" && pwd)
mkdir -p "$BUILD/tmp" "$BUILD/module-cache"
export TMPDIR="$BUILD/tmp" TMP="$BUILD/tmp" TEMP="$BUILD/tmp"
export CLANG_MODULE_CACHE_PATH="$BUILD/module-cache"
clang -std=c11 -O2 -Wall -Wextra -Werror -fmodules-cache-path="$BUILD/module-cache" \
    "$SOURCE/png_metrics.c" -framework CoreFoundation -framework CoreGraphics -framework ImageIO -o "$BUILD/png-metrics"
echo "$BUILD/png-metrics"
