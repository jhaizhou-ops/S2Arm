#!/usr/bin/env bash
# C4：独立 SurfaceView 上真实 swapchain present 3 帧，present fence 经 vk_track 退休；
# 再旋转屏幕触发第二窗口代际，验证新 swapchain 也完整退休。
set -euo pipefail
serial=${S2A_ADB:-$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')}
[ -n "$serial" ] || { echo "no adb device; C4 WSI probe NOT RUN" >&2; exit 2; }
accel=$(adb -s "$serial" shell settings get system accelerometer_rotation | tr -d '\r')
rotation=$(adb -s "$serial" shell settings get system user_rotation | tr -d '\r')
restore() {
    adb -s "$serial" shell settings put system accelerometer_rotation "$accel" >/dev/null 2>&1 || true
    adb -s "$serial" shell settings put system user_rotation "$rotation" >/dev/null 2>&1 || true
}
trap restore EXIT
adb -s "$serial" logcat -c
adb -s "$serial" shell am force-stop org.s2arm.android
adb -s "$serial" shell am start -W -n org.s2arm.android/.WsiProbeActivity >/dev/null
sleep 4
target_rotation=$(( rotation == 0 ? 1 : 0 ))
adb -s "$serial" shell settings put system accelerometer_rotation 0
adb -s "$serial" shell settings put system user_rotation "$target_rotation"
sleep 5
lines=$(adb -s "$serial" logcat -d 2>/dev/null | grep -E "wsi probe" | tail -6)
echo "$lines"
echo "$lines" | grep -q "generation=1" || { echo "generation 1 missing" >&2; exit 1; }
echo "$lines" | grep -q "generation=2" || { echo "generation 2 missing" >&2; exit 1; }
[ "$(echo "$lines" | grep -c "drain=0")" -ge 2 ] || { echo "drain failed" >&2; exit 1; }
echo "C4 WSI present fence + window generation: ok"
