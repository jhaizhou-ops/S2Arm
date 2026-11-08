#!/bin/bash
# 门禁手动：要真机：直签后用 devicectl 装到测试机1 跑探针
# 5b-5 探针一条命令：编 → 直签（借 io.s2arm.acnhpkg 的开发描述文件，跑完卸载）→ 测试机1 取锁（≤300 秒）→ 装、起、收标准输出 → 卸载放锁
# 用法：bash tests/probes/vtx32/run.sh <输出目录>
set -u
O=${1:?输出目录}; H=$(cd "$(dirname "$0")" && pwd); R=$(cd "$H/../../.." && pwd); B=io.s2arm.acnhpkg; mkdir -p "$O"
A=$O/Vtx32.app; rm -rf "$A"; mkdir -p "$A"
xcrun -sdk iphoneos clang -target arm64-apple-ios17.0 -O2 -fobjc-arc -o "$A/Vtx32" "$H/probe.m" -framework UIKit -framework Metal -framework Foundation || exit 1
plutil -create xml1 "$A/Info.plist"; for kv in CFBundleIdentifier=$B CFBundleExecutable=Vtx32 CFBundleName=Vtx32 CFBundlePackageType=APPL CFBundleShortVersionString=0.1 CFBundleVersion=1 MinimumOSVersion=17.0; do plutil -insert "${kv%%=*}" -string "${kv#*=}" "$A/Info.plist"; done
plutil -insert UIDeviceFamily -xml '<array><integer>1</integer></array>' "$A/Info.plist"
plutil -create xml1 "$O/ent.plist"
python3 -c "import re,sys;s=open('$R/pack/dev_sign.py').read();s=s.replace(\"miss = [k for k in NEED\",\"NEED = []\nmiss = [k for k in NEED\");open('$O/dev_sign_probe.py','w').write(s)"   # 探针不要增内存权限：本地副本去掉权限核对
. "$R/tools/machine.sh"; TEAM=${S2A_TEAM:-${S2A_TEAM_DEFAULT:-}}; [ -n "$TEAM" ] || { echo "【红】没设 S2A_TEAM（见 tools/machine.local.example）"; exit 1; }
/usr/bin/python3 "$O/dev_sign_probe.py" "$A" "$B" "$TEAM" "$O/ent.plist" || exit 1
source "$R/tools/devices.sh"; s2a_device 1 || exit 1; source "$R/tools/devlock.sh"
devlock_acquire "测试出包 5b-5 顶点 32 输出代价探针（借 ${B}，跑完卸载，≤300 秒）" 300 || exit 1
trap 'timeout 60 xcrun devicectl device uninstall app --device $SW_DEVICE $B > /dev/null 2>&1; devlock_release' EXIT
timeout 120 xcrun devicectl device install app --device "$SW_DEVICE" "$A" > "$O/install.log" 2>&1 || { echo "【红】装包失败：$(tail -2 "$O/install.log")"; exit 1; }
timeout 200 xcrun devicectl device process launch --device "$SW_DEVICE" --console --terminate-existing "$B" 2>&1 | grep -vE '^Launched|^Waiting|^Press|^$' | tee "$O/读数.txt"
grep -q 探针结束 "$O/读数.txt" || { echo "【红】探针没跑完"; exit 1; }
