#!/usr/bin/env bash
# C6 真机：preview 包弹软件键盘，输入 ASCII，点确定，核对 broker 回复。
# 仅证明 Android UI/IME/确认链路；不证明中文候选组字、direct 游戏内文本或两轨。
set -euo pipefail
serial=${S2A_ADB:-$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')}
[ -n "$serial" ] || { echo "no adb device; C6 probe NOT RUN" >&2; exit 2; }
adb -s "$serial" shell am force-stop org.s2arm.android
adb -s "$serial" logcat -c
adb -s "$serial" shell am start -W -n org.s2arm.android/.MainActivity --ez s2arm.keyboard_selftest true >/dev/null
sleep 3
adb -s "$serial" shell input text abc
sleep 1
adb -s "$serial" shell uiautomator dump /sdcard/s2a-ime.xml >/dev/null 2>&1
adb -s "$serial" pull /sdcard/s2a-ime.xml /tmp/s2a-ime.xml >/dev/null 2>&1
coords=$(python3 - <<'PY'
import re, sys
import xml.etree.ElementTree as ET
root = ET.parse('/tmp/s2a-ime.xml').getroot()
for node in root.iter('node'):
    if node.get('text') == '确定' or node.get('content-desc') == '确定':
        x1, y1, x2, y2 = map(int, re.findall(r'\d+', node.get('bounds')))
        print((x1 + x2) // 2, (y1 + y2) // 2)
        break
PY
)
[ -n "$coords" ] || { echo "confirm button not found" >&2; exit 1; }
adb -s "$serial" shell input tap $coords
sleep 2
line=$(adb -s "$serial" logcat -d 2>/dev/null | grep -F "Keyboard request completed: ok" | tail -1)
[ -n "$line" ] || { echo "no completed ok in logcat" >&2; exit 1; }
echo "C6 IME: $line"
