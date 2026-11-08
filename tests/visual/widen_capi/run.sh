#!/bin/bash
# 宽屏核心 C 接口对拍：NativeAOT 发布 graphics/widen 成动态库 → 编 capi_test.c → 跑。退出码 = 失败项数（编译失败 100）。
# 用法：bash tests/visual/widen_capi/run.sh [临时目录]
set -u
R=$(cd "$(dirname "$0")/../../.." && pwd)
T=${1:-$(mktemp -d)}
mkdir -p "$T"
rid=osx-arm64
timeout 600 dotnet publish -c Release -r $rid --artifacts-path "$T/art" -o "$T/lib" "$R/tests/visual/widen_capi" > "$T/publish.log" 2>&1 || { grep -E ' error ' "$T/publish.log" | sort -u | head -5; echo "NativeAOT 发布失败（$T/publish.log）"; exit 100; }
clang -O1 -Wall -Werror -I "$R/graphics/widen/export" -o "$T/capi_test" "$R/tests/visual/widen_capi/capi_test.c" "$T/lib/widen_capi.dylib" -Wl,-rpath,"$T/lib" || { echo "capi_test.c 编译失败"; exit 100; }
"$T/capi_test"
