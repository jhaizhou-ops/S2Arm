#!/bin/bash
# 产物最低系统版本单测（10-22 总指挥：两台编出的宿主 minos 一致，下限只有 tools/toolchain.env 一个来源），约 3 秒：bash tests/deploy_target_test.sh
# 期望 = tools/toolchain.env 里 MACOSX_DEPLOYMENT_TARGET / IPHONEOS_DEPLOYMENT_TARGET 两行（文件内容，不经被测脚本）：
#   ① source tools/toolchain.sh 后 clang 不带任何版本参数编宿主目标文件 → LC_BUILD_VERSION minos = macOS 下限（不随编译机系统版本：mini 27 / 本机 26）
#   ② 那个宿主目标文件的平台是 macOS（两个下限都导出成环境变量时，不带 -target 的宿主编译会被当成 iOS——10-22 实测 minos 18.0）
#   ③ graphics/metal 的 Makefile 编译参数里的下限 = macOS 下限 / iOS 下限（不再各写各的）
#   ④ 原生层 iOS 编译器（顶层 Makefile 引入 runtime/build.mk 后的 IOS_CC）目标 = arm64-apple-ios<iOS 下限>
#   ⑤ 原生层 iOS 包的 Info.plist MinimumOSVersion = iOS 下限（make -n 展开出包配方里写的值）
# 门禁的单测步在 mini 上跑：同一份单测在 mini 绿 = mini 编出的也是这个值。反证：旧 toolchain.sh（不导出下限）① 得编译机自己的系统版本、红
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0; trap 'rm -rf "$T"' EXIT
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
MAC=$(sed -n 's/^MACOSX_DEPLOYMENT_TARGET=//p' "$H/tools/toolchain.env"); IOS=$(sed -n 's/^IPHONEOS_DEPLOYMENT_TARGET=//p' "$H/tools/toolchain.env")
ck "toolchain.env 写了两个下限（macOS ${MAC:-无} / iOS ${IOS:-无}）" '[ -n "$MAC" ] && [ -n "$IOS" ]'
minos() { otool -l "$1" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}'; }
printf 'int main(void){return 0;}\n' > $T/h.c
( unset MACOSX_DEPLOYMENT_TARGET IPHONEOS_DEPLOYMENT_TARGET; source "$H/tools/toolchain.sh" && clang -c $T/h.c -o $T/m.o ) 2> $T/err
M=$(minos $T/m.o 2> /dev/null); P=$(otool -l $T/m.o 2> /dev/null | awk '/LC_BUILD_VERSION/{f=1} f&&/platform/{print $2; exit}')
ck "① 宿主目标文件 minos ${M:-?} = macOS 下限 ${MAC}（$(head -1 $T/err)）" '[ "$M" = "$MAC" ]'
ck "② 宿主目标文件平台是 macOS（LC_BUILD_VERSION platform ${P:-?}，期望 1）" '[ "$P" = 1 ]'
OF=$(make -s --no-print-directory -C "$H/graphics/metal" -f Makefile -f <(printf 'p:\n\t@echo $(OBJCFLAGS) / $(IOS_FLAGS)\n') OUT=$T/o p 2> /dev/null)
ck "③ graphics/metal 编译参数带 -mmacosx-version-min=${MAC} 与 -mios-version-min=${IOS}（${OF:0:160}）" '[[ "$OF" == *"-mmacosx-version-min=$MAC "* ]] && [[ "$OF" == *"-mios-version-min=$IOS"* ]]'
IC=$(make -s --no-print-directory -C "$H" -f Makefile -f <(printf 'p:\n\t@echo $(IOS_CC)\n') p 2> /dev/null)
ck "④ 原生层 IOS_CC 目标 arm64-apple-ios${IOS}（${IC:0:120}）" '[[ "$IC" == *"-target arm64-apple-ios$IOS "* ]]'
PL=$(make -n -s --no-print-directory -C "$H" ios 2> /dev/null | grep -o 'MinimumOSVersion=[^ ;]*' | head -1)
ck "⑤ 原生层 Info.plist ${PL:-（没展开出 MinimumOSVersion）} = iOS 下限 ${IOS}" '[ "$PL" = "MinimumOSVersion=$IOS" ]'
[ $bad = 0 ] && echo "部署目标单测全过" || { echo "部署目标单测有不通"; exit 1; }
