#!/usr/bin/env bash
# C1/C7（启动事务）：direct 产物在真机上启动 —— AUTO 选 generic 且在会话日志里写明原因；手动 direct 不降级。
# 只验证启动事务本身；合成包的 npdm 没有 ACI0，所以会话在模块加载后才失败（不当作游戏证据）。
#
# 前提（两条都要）：
#   1) 某个 direct 包目录（make_pack.py --direct-graphics 的产物）：S2A_PACK=<dir>
#   2) 已安装、已签名的同款 per-game APK 文件：S2A_APK=<apk 路径>
#      （app/build.gradle: S2ARM_ANDROID_GAME_DIR=<game_apk.py 的输出> -Ps2arm.nativeMode=game）
#   3) 设备上已装该 APK（本脚本只重装资源包，不装 APK）。
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
pack=${S2A_PACK:?S2A_PACK 指向 direct 包目录}
apk=${S2A_APK:?S2A_APK 指向已安装的 per-game APK}
serial=${S2A_ADB:-$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')}
[ -n "$serial" ] || { echo "no adb device; launch probe NOT RUN" >&2; exit 2; }
adb_shell() { adb -s "$serial" shell "$@"; }
title=$(python3 - "$pack" <<'PY'
import struct, sys
nacp = open(sys.argv[1] + '/ctl/control.nacp', 'rb').read()
print(f'{struct.unpack_from("<Q", nacp, 0x3038)[0]:016X}')
PY
)
pkg=org.s2arm.game.t$(echo "$title" | tr 'A-F' 'a-f')
work=$(mktemp -d "${TMPDIR:-/tmp}/s2a-launch.XXXXXX")
trap 'rm -rf "$work"' EXIT

python3 "$repo/android/tools/game_apk.py" --resources "$pack" "$apk" "$work/res" >/dev/null
import_dir=/sdcard/Android/data/$pkg/files/import
adb_shell rm -rf "$import_dir"
adb_shell am force-stop "$pkg"
adb_shell am start -W -n "$pkg/org.s2arm.android.MainActivity" >/dev/null
sleep 5
adb -s "$serial" push "$work/res" "$import_dir/" >/dev/null
# scoped storage：adb 建的子目录对 App 不可读（manifest=false），必须放开权限。
adb_shell chmod -R 0777 "$import_dir/$(basename "$work/res")"
adb -s "$serial" logcat -c
adb_shell am force-stop "$pkg"
adb_shell am start -W -n "$pkg/org.s2arm.android.MainActivity" >/dev/null
sleep 10
installed=$(adb -s "$serial" logcat -d | grep -E "Game (installed|already installed|build artifact updated)" | tail -1 || true)
[ -n "$installed" ] || { echo "resource package was not installed" >&2; exit 1; }
echo "install: $installed"

# 第一局：AUTO（不带 extra）。会话日志在下次启动时被 dump 出来。
adb -s "$serial" logcat -c
adb_shell am force-stop "$pkg"
adb_shell am start -W -n "$pkg/org.s2arm.android.MainActivity" >/dev/null
sleep 12
accepted=$(adb -s "$serial" logcat -d | grep -F "Game startup accepted:" | tail -1 || true)
[ -n "$accepted" ] || { echo "AUTO session was not accepted" >&2; exit 1; }
echo "auto: $accepted"
adb -s "$serial" logcat -c
adb_shell am force-stop "$pkg"
adb_shell am start -W -n "$pkg/org.s2arm.android.MainActivity" >/dev/null
sleep 10
selection=$(adb -s "$serial" logcat -d | grep -F "graphics selection:" | tail -1 || true)
[ -n "$selection" ] || { echo "no graphics selection line in the previous session log" >&2; exit 1; }
echo "$selection" | grep -q 'generic (direct backend not available)' \
    || { echo "AUTO did not fall back to generic for the expected reason" >&2; exit 1; }
echo "auto selection: $selection"

# 第二局：手动 direct（必须报红、不降级成 generic）。
adb -s "$serial" logcat -c
adb_shell am force-stop "$pkg"
adb_shell am start -W -n "$pkg/org.s2arm.android.MainActivity" --es s2arm.graphics_mode direct >/dev/null
sleep 12
manual=$(adb -s "$serial" logcat -d | grep -E "direct requested but backend is not available|Game runtime returned" | tail -2 || true)
echo "$manual" | grep -q 'direct requested but backend is not available' \
    || { echo "manual direct was not refused with the expected reason" >&2; echo "$manual" >&2; exit 1; }
echo "manual direct: $manual"
echo "C7 direct pack launch transaction: ok ($(adb_shell getprop ro.product.model | tr -d '\r'))"
