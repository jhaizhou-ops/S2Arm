#!/usr/bin/env bash
# W6.0 采集：同一窗口内收 logcat + SurfaceFlinger timestats + 设备/内存/热快照。
# 采集本身不逐帧落盘；SF timestats 与日志窗口用同一段墙钟，分析时用 w6_account.py。
#
# 用法：bash android/tools/w6_capture.sh --serial <serial> --package <pkg> \
#          --seconds 60 --out build/w6-run
# 环境：S2A_ADB 可代替 --serial；不设 package 时默认本机 D3 测试包。
set -euo pipefail
serial=${S2A_ADB:-}
package=org.s2arm.game.t01001b300b9be000
seconds=60
out=
while [ $# -gt 0 ]; do
    case "$1" in
        --serial) serial=$2; shift 2 ;;
        --package) package=$2; shift 2 ;;
        --seconds) seconds=$2; shift 2 ;;
        --out) out=$2; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
[ -n "$serial" ] || { echo "--serial or S2A_ADB is required" >&2; exit 2; }
[ "$seconds" -ge 1 ] || { echo "--seconds must be positive" >&2; exit 2; }
[ -n "$out" ] || { echo "--out is required" >&2; exit 2; }
mkdir -p "$out"
adb -s "$serial" shell dumpsys SurfaceFlinger --timestats -enable >/dev/null 2>&1 || true
adb -s "$serial" shell dumpsys SurfaceFlinger --timestats -clear >/dev/null 2>&1 || true
# clear 后的基线：结束再 dump 一次，两者相减才是与 logcat 同窗的显示账。
adb -s "$serial" shell dumpsys SurfaceFlinger --timestats -dump > "$out/sf-before.txt" 2>&1 || true
adb -s "$serial" logcat -c
start=$(date +%s)
# timeout 退出码 124 是正常结束；不让 set -e 误判。
timeout "$seconds" adb -s "$serial" logcat -v threadtime > "$out/logcat.txt" 2>&1 || true
end=$(date +%s)
adb -s "$serial" shell dumpsys SurfaceFlinger --timestats -dump > "$out/sf-after.txt" 2>&1 || true
cp "$out/sf-after.txt" "$out/sf-timestats.txt"
adb -s "$serial" shell dumpsys meminfo "$package" > "$out/meminfo.txt" 2>&1 || true
adb -s "$serial" shell dumpsys battery > "$out/battery.txt" 2>&1 || true
adb -s "$serial" shell dumpsys thermalservice > "$out/thermal.txt" 2>&1 || true
adb -s "$serial" shell getprop > "$out/props.txt" 2>&1 || true
path=$(adb -s "$serial" shell pm path "$package" | sed 's/^package://' | tr -d '\r' || true)
sha=
if [ -n "${path:-}" ]; then
    sha=$(adb -s "$serial" shell sha256sum "$path" 2>/dev/null | awk '{print $1}' | tr -d '\r' || true)
fi
{
    echo "serial=$serial"
    echo "package=$package"
    echo "seconds=$seconds"
    echo "wall_start_epoch=$start"
    echo "wall_end_epoch=$end"
    echo "apk_path=$path"
    echo "apk_sha256=$sha"
    echo "model=$(adb -s "$serial" shell getprop ro.product.model | tr -d '\r')"
    echo "android=$(adb -s "$serial" shell getprop ro.build.version.release | tr -d '\r')"
} > "$out/meta.txt"
echo "captured $out ($((end - start))s, apk=$sha)"
echo "next: python3 android/tools/w6_account.py --log $out/logcat.txt \\"
echo "        --sf-before $out/sf-before.txt --sf-after $out/sf-after.txt \\"
echo "        --seconds $((end - start)) --package $package --window $((end - start)) --strict"
