#!/bin/bash
# 门禁覆盖：shell/ launchers/shared/SaveSync/ runtime/build.mk tools/toolchain.env tests/shellui_ios_build_test.sh
# 带游戏库的容器壳（S2A_SHELLUI=1）的 iOS Release 编译进门禁（11-07 维护者）：main 上 ShellUI TouchLayoutEditorView 在 Xcode 27.1 Release iOS
#   「unable to type-check this expression in reasonable time」、容器壳编不过，却一路绿着合入——门禁原先只跑宿主层 swift test（macOS），不编 iOS Release。
#   这里跑出壳同一条命令（runtime/build.mk ios-shellui：xcodebuild -scheme S2ArmShellHost generic/platform=iOS Release），只编不签不装；门禁机上每个 Xcode 各编一遍，各约 30 秒。
set -u
cd "$(dirname "$0")/.." || exit 1
S2A_TC_QUIET=1 source tools/toolchain.sh > /dev/null || { echo "【红】取不到 Xcode（tools/toolchain.sh）"; exit 75; }
source tools/gmake.sh; MK=$(s2a_gmake) || exit 75
B=$(mktemp -d "${TMPDIR:-/tmp}/s2a-shellui.XXXXXX") || exit 1; trap 'rm -rf "$B"' EXIT
# 每个装着的 Xcode 都编一遍：类型检查超时随编译器版本变（11-07：Xcode 26.6 红、27.1 绿；玩家本机出壳用自己的 Xcode）
#   按 Xcode 版本号 + 构建号认（pack/jobs/toolchain.py installed_xcodes，11-07 gate-host：Xcode-27.1.app 是指向 Xcode-27.app 的软链、后者已被 App Store 升到 27.1，
#   按路径名会把同一份编两遍、标成 27 和 27.1），当前选中的那份排第一、同版本同构建号的不再重复
XCS=("$DEVELOPER_DIR"); while IFS= read -r d; do [ -n "$d" ] && XCS+=("$d"); done < <("${S2A_PY:-python3}" - "$DEVELOPER_DIR" << 'PY'
import os, plistlib, sys
sys.path.insert(0, "pack/jobs"); from toolchain import installed_xcodes
cur = sys.argv[1]; app = os.path.dirname(os.path.realpath(cur))
def key(app):
    try: v = plistlib.loads(open(os.path.join(app, "Info.plist"), "rb").read()).get("CFBundleShortVersionString", "")
    except (OSError, ValueError): v = ""
    try: b = plistlib.loads(open(os.path.join(app, "version.plist"), "rb").read()).get("ProductBuildVersion", "")
    except (OSError, ValueError): b = ""
    return v, b
ck = key(app)
for _, vs, b, d in installed_xcodes():
    if (vs, b) != ck and os.path.realpath(d) != os.path.realpath(cur): print(d)
PY
)
bad=0; built=0; skipped=0
for dd in "${XCS[@]}"; do
  v=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$dd/../Info.plist" 2> /dev/null || echo "?")-$(/usr/libexec/PlistBuddy -c "Print :ProductBuildVersion" "$dd/../version.plist" 2> /dev/null || echo "?"); t0=$SECONDS
  if "$MK" -s ios-shellui S2A_SHELLUI=1 BUILD="$B/$v/build" DEVELOPER_DIR="$dd" > "$B/$v.log" 2>&1 \
     && for o in S2ArmShellHost.o S2ArmShellBridge.o ShellUI.o ShellControllers.o; do [ -s "$B/$v/build/ios/shellui/Build/Products/Release-iphoneos/$o" ] || exit 1; done; then
    echo "通 Xcode ${v}：游戏库界面 iOS Release 编过（$((SECONDS - t0)) 秒）"; built=$((built + 1))
  elif grep -qs "is not installed. Please download and install the platform" "$B/$v.log" "$B/$v/build/ios/shellui/xcodebuild.log"; then
    # 11-07 gate-host：Xcode 26.6 带 iOS 26.5 SDK 却没下 iOS 平台组件，xcodebuild 找不到 generic/platform=iOS，任何 iOS 程序都编不了——是这台机的 Xcode 装得不全，
    #   不是代码问题（同版 Xcode 在装全的机器上编过）。不判红但明说；一个 Xcode 都没编成才红（没有覆盖不能报绿）
    echo "跳过 Xcode ${v}：这台机的 Xcode ${v} 没装 iOS 平台组件（xcodebuild -downloadPlatform iOS 补），编不了任何 iOS 程序，不是代码问题"; skipped=$((skipped + 1))
  else
    echo "不通 Xcode ${v}：游戏库界面 iOS Release 编不过（S2A_SHELLUI=1 的容器壳出不来）"; grep -m3 "error:" "$B/$v.log" "$B/$v/build/ios/shellui/xcodebuild.log" 2> /dev/null | cut -c1-240; bad=1
  fi
done
[ $bad = 0 ] || { echo "游戏库界面 iOS Release 有 Xcode 编不过"; exit 1; }
[ $built -gt 0 ] || { echo "【红】游戏库界面 iOS Release：${#XCS[@]} 个 Xcode 一个都没编成（跳过 ${skipped} 个缺组件），没有覆盖"; exit 1; }
echo "游戏库界面 iOS Release：${built}/${#XCS[@]} 个 Xcode 编过$([ $skipped = 0 ] || echo "，${skipped} 个缺 iOS 平台组件跳过")"
