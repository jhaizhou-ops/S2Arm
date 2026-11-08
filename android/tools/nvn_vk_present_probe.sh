#!/usr/bin/env bash
# 新后端 present：在 WsiProbeActivity 的真实 Surface 上清两帧并 present。
# 需要已安装的 per-game APK（含 WsiProbeActivity 与新后端代码）；包名可用 S2A_PKG 覆盖。
set -euo pipefail
serial=${S2A_ADB:-$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')}
[ -n "$serial" ] || { echo "no adb device; present probe NOT RUN" >&2; exit 2; }
pkg=${S2A_PKG:-org.s2arm.game.t01001b300b9be000}
adb -s "$serial" shell am force-stop "$pkg"
adb -s "$serial" logcat -c
adb -s "$serial" shell am start -W -n "$pkg/org.s2arm.android.WsiProbeActivity" >/dev/null
sleep 5
lines=$(adb -s "$serial" logcat -d 2>/dev/null | grep -E 'nvn-vk (session )?present' | tail -2)
echo "$lines"
echo "$lines" | grep -qE 'nvn-vk (session )?present: 2/2' || { echo "nvn-vk present failed" >&2; exit 1; }
echo "nvn-vk present: ok"
