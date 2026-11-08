#!/bin/bash
# 随 App 分发的预编静态库（libvpx / dav1d，services/prebuilt_lib.sh + launchers/macos/bundle_engine.py bundle_prebuilt_libs）：bash tests/prebuilt_lib_test.sh
# 期望（按规则手写）：
#   ① 发版打包 bundle_prebuilt_libs 往 Binaries/Prepare 放出 vpx / dav1d × ios-arm64 / osx-arm64 四份：库、头文件、build.txt（键 = build.sh --key、lib_sha256 = 库的 sha256），
#      库与发版机缓存里构建出的那份逐字节相同（VP8 现有路径产出不变）
#   ② 玩家出包环境（S2A_PREBUILT_TOOLS 指到这份、PATH 只有系统目录、缓存目录指到空处）：四份 build.sh 都回预编库路径、rc=0，缓存目录没建（没构建）
#   ④ 构建键只按内容：引擎换个路径（发版机与玩家机路径不同）键不变
#   ③ build.txt 的键改一位 → rc≠0 且报「构建键」；库改一个字节 → rc≠0 且报「sha256」；预编目录缺 → rc≠0 且报「没有」，都不回落现编
# 门禁覆盖：services/prebuilt_lib.sh services/vpx/build.sh services/dav1d/build.sh launchers/macos/bundle_engine.py
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0; trap 'rm -rf "$T"' EXIT
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
PY=${S2A_PYTHON:-python3}
"$PY" -B -c "
import sys; sys.path.insert(0, '$H/launchers/macos'); sys.path.insert(0, '$H/pack/jobs')
from pathlib import Path
from bundle_engine import bundle_prebuilt_libs
bundle_prebuilt_libs(Path('$T/pre'))
" > "$T/bundle.log" 2>&1 || { echo "不通 ① bundle_prebuilt_libs 失败：$(tail -3 "$T/bundle.log")"; exit 1; }
for n in vpx dav1d; do for r in ios-arm64 osx-arm64; do
  d=$T/pre/libs/$n/$r; lib=libs2a_$n.a; built=$(bash "$H/services/$n/build.sh" "$r" | tail -1)
  ck "① $n ${r}：库与构建缓存里那份逐字节相同、build.txt 键与 sha256 对" \
    '[ -f "$d/$lib" ] && cmp -s "$d/$lib" "$built" && [ -d "$d/include" ] && grep -qx "key=$(bash "$H/services/$n/build.sh" "$r" --key)" "$d/build.txt" && grep -qx "lib_sha256=$(shasum -a 256 "$d/$lib" | cut -c1-64)" "$d/build.txt"'
  out=$(env -i HOME="$T/home" PATH=/usr/bin:/bin:/usr/sbin:/sbin S2A_PREBUILT_TOOLS="$T/pre" S2A_VPX_CACHE="$T/nocache" S2A_DAV1D_CACHE="$T/nocache" S2A_RUN_ROOT="$T/run" bash "$H/services/$n/build.sh" "$r" 2> "$T/err"); rc=$?
  ck "② $n ${r}：玩家出包环境回预编库、不构建（rc=${rc}）" '[ $rc = 0 ] && [ "$out" = "$d/$lib" ] && [ ! -e "$T/nocache" ] && [ ! -e "$T/run" ]'
done; done
run() { env -i HOME="$T/home" PATH=/usr/bin:/bin S2A_PREBUILT_TOOLS="$1" S2A_VPX_CACHE="$T/nocache" S2A_RUN_ROOT="$T/run" bash "$H/services/vpx/build.sh" ios-arm64 > /dev/null 2> "$T/err"; }
cp -R "$T/pre" "$T/k"; f=$T/k/libs/vpx/ios-arm64/build.txt; sed 's/^key=\(.*\)./key=\1x/' "$f" > "$f.new" && mv "$f.new" "$f"
run "$T/k"; rc=$?; ck "③ 键不符报红不现编（rc=${rc}）" '[ $rc != 0 ] && grep -q 构建键 "$T/err" && [ ! -e "$T/nocache" ]'
cp -R "$T/pre" "$T/l"; printf 'x' | dd of="$T/l/libs/vpx/ios-arm64/libs2a_vpx.a" bs=1 seek=100 conv=notrunc 2> /dev/null
run "$T/l"; rc=$?; ck "③ 库被改报红不现编（rc=${rc}）" '[ $rc != 0 ] && grep -q sha256 "$T/err" && [ ! -e "$T/nocache" ]'
mkdir -p "$T/empty"; run "$T/empty"; rc=$?; ck "③ 没有预编库报红不现编（rc=${rc}）" '[ $rc != 0 ] && grep -q 没有 "$T/err" && [ ! -e "$T/nocache" ]'
mkdir -p "$T/其他 路径/services" "$T/其他 路径/tools"; cp -R "$H/services/vpx" "$H/services/dav1d" "$H/services/prebuilt_lib.sh" "$T/其他 路径/services/"; cp "$H/tools/toolchain.env" "$T/其他 路径/tools/"
mkdir -p "$T/其他 路径/platforms/android/tools"; cp "$H/android/tools/fetch_source.sh" "$T/其他 路径/platforms/android/tools/"
for n in vpx dav1d; do a=$(bash "$H/services/$n/build.sh" ios-arm64 --key); b=$(bash "$T/其他 路径/services/$n/build.sh" ios-arm64 --key)
  ck "④ $n 构建键与引擎路径无关（$a / ${b}）" '[ -n "$a" ] && [ "$a" = "$b" ]'; done
[ $bad = 0 ] && echo "prebuilt_lib 单测全过" || { echo "prebuilt_lib 单测有不通"; exit 1; }
