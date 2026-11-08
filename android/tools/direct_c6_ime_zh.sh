#!/usr/bin/env bash
# C6 real-device Chinese IME rehearsal for the diagnostic preview broker.
#
#   bash android/tools/direct_c6_ime_zh.sh confirm
#   bash android/tools/direct_c6_ime_zh.sh cancel
#   bash android/tools/direct_c6_ime_zh.sh stop
#
# Requires:
#   - adb device and the diagnostic APK org.s2arm.android installed;
#   - Gboard as the default IME and its 简体中文 (9-key) subtype enabled;
#   - a 1220x2712 / 480 dpi portrait device (defaults below; override with S2A_C6_*).
#
# Scope: the diagnostic preview uses the same HostApi UI broker, JNI and
# HostKeyboard as the game shell, but it is not the generic Ryujinx applet and
# not a direct game. It proves the Android IME -> broker -> result=0 path only.
# The script never logs reply text; S2Arm logs status and character/UTF-8 lengths.
set -euo pipefail

case=${1:-}
case "$case" in confirm|cancel|stop) ;; *) echo "usage: $0 confirm|cancel|stop" >&2; exit 2 ;; esac
serial=${S2A_ADB:-$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')}
[ -n "$serial" ] || { echo "no adb device; C6 zh NOT RUN" >&2; exit 2; }
out=${S2A_C6_OUT:-$PWD/build/c6-ime}
mkdir -p "$out"
log=$out/c6-$case.logcat

adb_shell() { adb -s "$serial" shell "$@"; }
dump_ui() {
    adb_shell uiautomator dump /sdcard/s2a-c6-zh.xml >/dev/null 2>&1 || true
    adb -s "$serial" pull /sdcard/s2a-c6-zh.xml "$1" >/dev/null 2>&1 || true
}
# Prints the EditText center, or nothing.
edit_center() {
    python3 - "$1" <<'PY'
import re, sys, xml.etree.ElementTree as ET
try:
    root = ET.parse(sys.argv[1]).getroot()
except Exception:
    raise SystemExit
for n in root.iter('node'):
    if n.get('class') == 'android.widget.EditText':
        x1, y1, x2, y2 = map(int, re.findall(r'\d+', n.get('bounds')))
        print((x1 + x2) // 2, (y1 + y2) // 2)
        break
PY
}
# Prints "<center-x> <center-y> <enabled>" for a button with the given text.
button() {
    python3 - "$1" "$2" <<'PY'
import re, sys, xml.etree.ElementTree as ET
try:
    root = ET.parse(sys.argv[1]).getroot()
except Exception:
    raise SystemExit
for n in root.iter('node'):
    if n.get('text') == sys.argv[2]:
        x1, y1, x2, y2 = map(int, re.findall(r'\d+', n.get('bounds')))
        print((x1 + x2) // 2, (y1 + y2) // 2, 'true' if n.get('enabled') == 'true' else 'false')
        break
PY
}
# Prints the EditText text.
edit_text() {
    python3 - "$1" <<'PY'
import sys, xml.etree.ElementTree as ET
try:
    root = ET.parse(sys.argv[1]).getroot()
except Exception:
    raise SystemExit
for n in root.iter('node'):
    if n.get('class') == 'android.widget.EditText':
        print(n.get('text') or '')
        break
PY
}

# The preview diagnostic can run portrait; the game/direct shell uses its own
# window mode. Save and restore the shell rotation so this script does not
# leave the device rotated.
old_accel=$(adb_shell settings get system accelerometer_rotation | tr -d '\r')
old_rot=$(adb_shell settings get system user_rotation | tr -d '\r')
restore() {
    adb_shell settings put system accelerometer_rotation "$old_accel" >/dev/null 2>&1 || true
    if [[ $old_rot =~ ^[0-3]$ ]]; then
        adb_shell settings put system user_rotation "$old_rot" >/dev/null 2>&1 || true
    else
        adb_shell settings delete system user_rotation >/dev/null 2>&1 || true
    fi
    adb_shell am force-stop org.s2arm.android >/dev/null 2>&1 || true
}
trap restore EXIT

ime=$(adb_shell settings get secure default_input_method | tr -d '\r')
[ "$ime" = "com.google.android.inputmethod.latin/com.android.inputmethod.latin.LatinIME" ] || {
    echo "Gboard is not the default IME ($ime); install/enable Gboard 简体中文 first" >&2
    exit 2
}
if ! adb_shell dumpsys input_method | grep -q 'mSubtypeName=简体中文'; then
    echo "Gboard 简体中文 subtype is not enabled; enable it in Gboard settings" >&2
    exit 2
fi

adb_shell settings put system accelerometer_rotation 0
adb_shell settings put system user_rotation 0
adb_shell am force-stop org.s2arm.android >/dev/null 2>&1 || true
adb_shell logcat -c
adb_shell am start -W -n org.s2arm.android/.MainActivity \
    --ez s2arm.keyboard_selftest true --ei s2arm.keyboard_mode 5 \
    --ei s2arm.keyboard_min 1 --ei s2arm.keyboard_max 16 >/dev/null

edit=
for _ in $(seq 1 20); do
    dump_ui "$out/$case-dialog.xml"
    edit=$(edit_center "$out/$case-dialog.xml")
    [ -n "$edit" ] && break
    sleep 0.5
done
[ -n "$edit" ] || { echo "keyboard dialog not found" >&2; exit 1; }
read -r edit_x edit_y <<<"$edit"
adb_shell input tap "$edit_x" "$edit_y"
sleep 1
if ! adb_shell dumpsys input_method | grep -q 'mInputShown=true'; then
    echo "system IME did not show" >&2
    exit 1
fi

if [ "$case" = cancel ]; then
    read -r x y enabled <<<"$(button "$out/$case-dialog.xml" 取消)"
    [ -n "${x:-}" ] || { echo "cancel button not found" >&2; exit 1; }
    adb_shell input tap "$x" "$y"
elif [ "$case" = stop ]; then
    # Start composing, then ask the session to stop through the HostApi table.
    adb_shell input text nihao
    sleep 1
    adb_shell am start -n org.s2arm.android/.MainActivity --ei s2arm.request_stop 0 >/dev/null 2>&1 || true
    sleep 3
else
    # Hardware key events enter Gboard, which composes pinyin and shows the
    # candidate strip. Tap the spacebar to commit the highlighted first
    # candidate (你好); this avoids the Gboard 9-key candidate row, which is
    # above the IME window's touchable region on this device/insets setup.
    adb_shell input text nihao
    sleep 1.5
    width=$(adb_shell wm size | sed -n 's/.*: \([0-9]*\)x\([0-9]*\).*/\1/p' | head -1)
    height=$(adb_shell wm size | sed -n 's/.*: \([0-9]*\)x\([0-9]*\).*/\2/p' | head -1)
    width=${width:-1220}; height=${height:-2712}
    adb_shell input tap $((width / 2)) $((height * 829 / 1000))
    sleep 1
    dump_ui "$out/$case-after.xml"
    text=$(edit_text "$out/$case-after.xml")
    [ "$text" = "你好" ] || { echo "candidate selection did not produce 你好 (got '${text}')" >&2; exit 1; }
    read -r x y enabled <<<"$(button "$out/$case-after.xml" 确定)"
    [ -n "${x:-}" ] && [ "$enabled" = true ] || {
        echo "confirm button not found/enabled" >&2
        exit 1
    }
    adb_shell input tap "$x" "$y"
fi

sleep 2
adb_shell logcat -d -s S2Arm:I > "$log"

if [ "$case" = cancel ]; then
    grep -F "Keyboard selftest reply: rc=0 status=cancel" "$log"
    grep -F "Keyboard request completed: cancel, result=0" "$log"
elif [ "$case" = stop ]; then
    grep -F "Keyboard selftest reply: rc=-4" "$log"   # stop wakes the waiter
    grep -F "HostApi stop requested: exit requested" "$log"
    if adb_shell logcat -d -s AndroidRuntime:E | grep -q 'org.s2arm.android'; then
        echo "fatal AndroidRuntime error for org.s2arm.android" >&2
        exit 1
    fi
else
    grep -F "Keyboard selftest reply: rc=0 status=ok" "$log"
    grep -F "Keyboard request completed: ok, chars=2, utf8=6, result=0" "$log"
fi
echo "C6 zh $case: ok ($log)"
