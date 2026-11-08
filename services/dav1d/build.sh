#!/bin/bash
# dav1d（VideoLAN 的 AV1 解码器，BSD-2-Clause）静态库：AV1 软件解码，VideoToolbox 报不支持 AV1 的机器（无 AV1 硬件解码：M1 / M2、A16 及更早）
#   上给 Switch 2 直连档接管的 nn::codec AV1 解码器用（graphics/nvn/gfx/nvn/nvn2_codec.c；火纹 Fortune's Weave 82 支片头全是 AV1）。有硬件的机器照走 VideoToolbox。
# 用法：bash services/dav1d/build.sh [osx-arm64|osx-x64|ios-arm64] → 最后一行输出 libs2a_dav1d.a 路径（dav1d + C 垫片 s2a_av1.c）。按版本 / 垫片哈希缓存在 ~/.s2arm/run/s2arm/cache/dav1d，命中秒过。
# 源码按固定版本 + sha256（与 downloads.videolan.org 同目录的 .sha256 一致）取，不进仓库；源码包按 sha256 缓存在 ${S2A_BUILD_CACHE:-~/.cache/s2arm-build}/sources/（android/tools/fetch_source.sh）。
#   做法同 services/vpx/build.sh、services/opus/build.sh；dav1d 只有 meson 构建（要 meson + ninja，Homebrew 装）。arm64 汇编是 .S、clang 直接编，不要 nasm；Intel 关汇编。
set -euo pipefail
RID=${1:-osx-arm64}
VER=1.5.4; SHA=686616b7c69eb88d44459391ab25cac13b6647a3b288835c5784e71c1514a5c5
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
# 源码包按 sha256 进本机共享缓存（S2A_BUILD_CACHE/sources），命中不联网；下载按进展判挂死
source "$ROOT/android/tools/fetch_source.sh"
# 产物下限只取统一工具链那两行
TCE=$ROOT/tools/toolchain.env; MMAC=$(sed -n 's/^MACOSX_DEPLOYMENT_TARGET=//p' "$TCE"); MIOS=$(sed -n 's/^IPHONEOS_DEPLOYMENT_TARGET=//p' "$TCE")
[ -n "$MMAC" ] && [ -n "$MIOS" ] || { echo "🔴 $(basename "$(dirname "$0")")：$TCE 里没有部署目标" >&2; exit 1; }
# 构建键：版本 + 本脚本与系统下限 + 垫片，只按内容算、不含路径（发版机与玩家机引擎路径不同；缓存目录、预编库都按它认）；--key 只打印它（发版打包 bundle_engine.py 记进 build.txt）
H1=$( { cat "$0"; echo "$MMAC $MIOS"; } | shasum -a 256 | cut -c1-12); K=$(cat "$ROOT/services/dav1d/s2a_av1.c" "$0" | shasum -a 256 | cut -c1-12); KEY=$VER-$H1-$K
[ "${2:-}" = --key ] && { echo "$KEY"; exit 0; }
# 出包作业（S2A_PREBUILT_TOOLS）用 App 里的预编库，不构建（services/prebuilt_lib.sh）
source "$ROOT/services/prebuilt_lib.sh"; s2a_prebuilt_lib dav1d "$RID" "$KEY" libs2a_dav1d.a
# 整机级缓存：键 = 本脚本内容（含版本与 sha256）+ 平台，各工作树共用
C=${S2A_DAV1D_CACHE:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/cache/dav1d}; mkdir -p "$C"
# 下限进键：改了就重编
OUT=$C/$RID-$VER-$H1
# 几棵树同时编同一键时排队（.tmp 名字不撞）
until mkdir "$C/.lock" 2> /dev/null; do p=$(cat "$C/.lock/pid" 2> /dev/null || true); [ -n "$p" ] && ! kill -0 "$p" 2> /dev/null && rm -rf "$C/.lock"; sleep 0.5; done
echo $$ > "$C/.lock/pid"; trap 'rm -rf "$C/.lock"' EXIT
ARCH=arm64; CPU=aarch64; ASM=true; SUB=macos
case $RID in
  osx-arm64) MIN=-mmacosx-version-min=$MMAC; SDK=macosx ;;
  osx-x64) ARCH=x86_64; CPU=x86_64; ASM=false; MIN=-mmacosx-version-min=$MMAC; SDK=macosx ;;
  ios-arm64) MIN=-miphoneos-version-min=$MIOS; SDK=iphoneos; SUB=ios ;;
  *) echo "🔴 dav1d：不认识的平台 $RID" >&2; exit 1 ;;
esac
CC="xcrun --sdk $SDK clang -arch $ARCH $MIN"
# 本机缓存跟编译器走（审计 #1534 P1-107）：构建键不含编译器（发版机与玩家机的预编库按它认，不能带本机版本），本机缓存目录名另带 clang 版本行的哈希，toolchain.txt 记原文备查
TCV=$($CC --version 2> /dev/null | sed -n 1p) || TCV=
[ -n "$TCV" ] || { echo "🔴 dav1d：取不到 $SDK clang 的版本行（xcrun 失败），不出库" >&2; exit 1; }
# 编译器进本机缓存目录名（11-05 服务层单测偶发 rc=134）：原先同一目录记 toolchain.txt、版本行不同就 rm -rf 整个目录重编；本机两套 Xcode
#   （门禁经 tools/toolchain.sh 用 S2A_DEVELOPER_DIR 那套、直接跑用 xcode-select 那套）版本行不同，轮流互删，把别的树单测正要 dlopen 的动态库删掉。
#   按编译器分目录后已出好的目录不再被改写；构建键（--key / 预编库）仍不含编译器
OUT=$OUT-$(printf '%s' "$TCV" | shasum -a 256 | cut -c1-8)
if [ ! -s "$OUT/libdav1d.a" ]; then
  # 只在开发机 / 发版机构建（玩家机器用 App 里的预编库，见 services/prebuilt_lib.sh，走不到这里）：要 Homebrew 的 meson 与 ninja，缺了构建失败那行写明
  TXZ=$(s2a_source_fetch "dav1d-$VER.tar.xz" "https://downloads.videolan.org/pub/videolan/dav1d/$VER/dav1d-$VER.tar.xz" "$SHA") || { echo "🔴 dav1d：取不到源码包" >&2; exit 1; }
  W=$OUT.tmp; rm -rf "$W"; mkdir -p "$W/src"
  tar xJf "$TXZ" -C "$W/src" --strip-components 1
  # 缓存在带空格目录（启动器：~/Library/Application Support）时走无空格别名（tools/nospace.sh），同 vpx / opus
  source "$ROOT/tools/nospace.sh"; WN=$(s2a_nospace "$W")
  # 交叉文件：三个平台同一写法（本机 arm64 也走它，编译器与下限只从这里来）
  cat > "$W/cross.txt" << EOF
[binaries]
c = ['xcrun', '--sdk', '$SDK', 'clang', '-arch', '$ARCH']
ar = ['xcrun', '--sdk', '$SDK', 'ar']
strip = ['xcrun', '--sdk', '$SDK', 'strip']
[built-in options]
c_args = ['$MIN', '-ffile-prefix-map=$WN/src=dav1d']
c_link_args = ['$MIN']
[host_machine]
system = 'darwin'
subsystem = '$SUB'
cpu_family = '$CPU'
cpu = '$ARCH'
endian = 'little'
EOF
  # 8 / 16 位都编（10 位片子也能解）；不带工具 / 示例 / 测试 / 文档；静态库
  ( cd "$WN/src" && meson setup "$WN/obj" --cross-file "$WN/cross.txt" --buildtype=release --default-library=static \
      -Dbitdepths=8,16 -Denable_asm=$ASM -Denable_tools=false -Denable_examples=false -Denable_tests=false -Denable_docs=false -Dlogging=false \
      > "$W/configure.log" 2>&1 && ninja -C "$WN/obj" > "$W/make.log" 2>&1 ) || { echo "🔴 dav1d：$RID 构建失败（$W/*.log；开发 / 发版机要 Homebrew 的 meson 与 ninja：brew install meson ninja）" >&2; tail -5 "$W"/*.log >&2; exit 1; }
  mkdir -p "$W/out/include/dav1d"
  cp "$W/obj/src/libdav1d.a" "$W/out/"; cp "$W/src/include/dav1d/"*.h "$W/out/include/dav1d/"; cp "$W/src/COPYING" "$W/out/"
  printf '%s\n' "$TCV" > "$W/out/toolchain.txt"
  rm -rf "$OUT"; mv "$W/out" "$OUT"; rm -rf "$W"
fi
# 垫片与 dav1d 合成一个静态库（直连层按函数名调它；服务层要用时同 vpx 走 DirectPInvoke s2a_dav1d）
L=$OUT/s2a-$K/libs2a_dav1d.a
if [ ! -s "$L" ]; then
  mkdir -p "$OUT/s2a-$K.tmp"
  $CC -O2 -fPIC -I"$OUT/include" -c "$ROOT/services/dav1d/s2a_av1.c" -o "$OUT/s2a-$K.tmp/s2a_av1.o"
  libtool -static -o "$OUT/s2a-$K.tmp/libs2a_dav1d.a" "$OUT/libdav1d.a" "$OUT/s2a-$K.tmp/s2a_av1.o" 2>/dev/null
  rm -rf "$OUT/s2a-$K"; mv "$OUT/s2a-$K.tmp" "$OUT/s2a-$K"
fi
touch "$OUT"   # 取用即更新目录时间：tools/gc.sh 每平台留 2 份、30 分钟内动过的不删，在用的这份不被别的键挤掉
echo "$L"
