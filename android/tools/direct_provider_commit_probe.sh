#!/usr/bin/env bash
# C1（提交与恢复）：真机上 provider 建出 VkDevice 后 direct 真的 commit（写 attempt 锁），
# 下一局因为"上一局 direct 没正常收局"回到 generic —— 这就是故障下局 generic 的真实链路。
# 用合成 direct 包 + per-game APK（引擎开关构建），不涉及游戏内容。
#
# 前提：
#   S2A_PACK=<direct 包目录>  S2A_APK=<用 S2ARM_ANDROID_VK_ENGINE=1 -Ps2arm.nativeMode=game 构建的 APK>
#   （APK 与包必须是同一次构建：资源包记录 APK 的 sha256）
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
pack=${S2A_PACK:?S2A_PACK 指向 direct 包目录}
apk=${S2A_APK:?S2A_APK 指向 per-game APK}
serial=${S2A_ADB:-$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')}
[ -n "$serial" ] || { echo "no adb device; provider commit probe NOT RUN" >&2; exit 2; }
adb_shell() { adb -s "$serial" shell "$@"; }
title=$(python3 - "$pack" <<'PY'
import struct, sys
nacp = open(sys.argv[1] + '/ctl/control.nacp', 'rb').read()
print(f'{struct.unpack_from("<Q", nacp, 0x3038)[0]:016X}')
PY
)
pkg=org.s2arm.game.t$(echo "$title" | tr 'A-F' 'a-f')
work=$(mktemp -d "${TMPDIR:-/tmp}/s2a-provider.XXXXXX")
trap 'rm -rf "$work"' EXIT
python3 "$repo/android/tools/game_apk.py" --resources "$pack" "$apk" "$work/res" >/dev/null

launch() { adb -s "$serial" logcat -c; adb_shell am force-stop "$pkg"; adb_shell am start -W -n "$pkg/org.s2arm.android.MainActivity" >/dev/null; sleep "${1:-12}"; }

# 全新安装（清掉旧 attempt 锁），把资源包装进去
adb -s "$serial" uninstall "$pkg" >/dev/null 2>&1 || true
adb -s "$serial" install "$apk" 2>&1 | tail -1
import_dir=/sdcard/Android/data/$pkg/files/import
launch 5
adb -s "$serial" push "$work/res" "$import_dir/" >/dev/null
adb_shell chmod -R 0777 "$import_dir/$(basename "$work/res")"
launch 12
grep -q . /dev/null || true
installed=$(adb -s "$serial" logcat -d | grep -E "Game (installed|already installed|build artifact updated)" | tail -1 || true)
[ -n "$installed" ] || { echo "resource package was not installed" >&2; exit 1; }
echo "install: $installed"

# 第二局：上一局（第一局）的会话日志在这里 dump 出来 —— 应该已经 commit 到 direct。
launch 10
first=$(adb -s "$serial" logcat -d | grep -E 'prev\| \[s2a\] graphics selection:' | tail -1 || true)
echo "run1: $first"
echo "$first" | grep -q 'direct (direct committed before relocation)' \
    || { echo "provider did not commit direct on the first run" >&2; exit 1; }
echo "$first" | grep -q 'devices=1 queues=1' || { echo "provider did not create a device/queue" >&2; exit 1; }

# 第三局：上一局（第二局）dumped 的应该是"上一局 direct 没正常收局 → generic"。
launch 12
launch 10
second=$(adb -s "$serial" logcat -d | grep -E 'prev\| \[s2a\] graphics selection:' | tail -1 || true)
echo "run2: $second"
echo "$second" | grep -q 'generic (previous direct attempt did not end normally)' \
    || { echo "the attempt lock did not send the next run to generic" >&2; exit 1; }
echo "C1 direct commit + attempt lock recovery: ok ($(adb_shell getprop ro.product.model | tr -d '\r'))"
