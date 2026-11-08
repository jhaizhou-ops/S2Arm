#!/bin/bash
# 卸载测试机上的实验 App（10-21 画面·着色器线：实验身份连跑几局后腾手机空间，各线不直接调 devicectl）：tools/dev_uninstall.sh <1|2> <包名>
#   只认实验身份 io.s2arm-exp.*（pack/ipa.sh 私有根出的「<款名> 实验」）；正式身份 io.s2arm.* 一律拒绝（jhz 试听的包与存档在里面，卸了不可恢复）
#   拿该机设备锁（tools/devlock.sh，与调度派的局互斥），devicectl 用它自带的 --timeout；卸前、卸后各查一次，机上本来没装 = 绿；卸前先拉回管线种子来源（pso_pull）
# 退出码：0 卸掉了 / 本来没装；1 设备 / 锁 / 卸载失败；2 用法或身份不允许
set -u
TOOLS=$(cd "$(dirname "$0")" && pwd); DEV=${1:-}; B=${2:-}
[ -n "$DEV" ] && [ -n "$B" ] || { echo "用法：tools/dev_uninstall.sh <1|2> <包名>" >&2; exit 2; }
case $B in io.s2arm-exp.*) ;; *) echo "【红】只卸实验身份 io.s2arm-exp.*，拒绝 ${B}（正式身份里有 jhz 的包与存档）" >&2; exit 2;; esac
source "$TOOLS/devices.sh"; s2a_device "$DEV" || exit 1
DC=${S2A_DEVICECTL:-xcrun devicectl}; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
dcp() { local t=$1 s0=$SECONDS r; shift; timeout $((t + ${S2A_DC_MARGIN:-30})) $DC "$@" --timeout "$t"; r=$?; [ $r != 0 ] && [ $((SECONDS - s0)) -ge "$t" ] && r=124; return $r; }
installed() { dcp 60 device info apps --device "$SW_DEVICE" --bundle-id "$B" --json-output "$T/apps.json" > /dev/null 2>&1 || return 2
  python3 -c "
import json, sys
try: apps = json.load(open(sys.argv[1]))['result']['apps']
except Exception: sys.exit(2)   # 读不出 / 结构不对 = 不知道装没装（审计 P1-50：原先 traceback 退出码 1 被当成「没装」跳过卸载）
sys.exit(0 if apps else 1)" "$T/apps.json"; }
# 卸前拉回管线种子来源（总指挥 11-02：卸载连 App 容器一起清，人玩 / 测试局首遇现编记下的 pso_user.tsv 会跟着丢）：机上 Documents/wire/<程序号>/pso_user.tsv
#   逐个拉回 pso_seed/<程序号>/<包名>_<时间>_卸前.tsv（同 tools/dev_run.sh 装前拉回；出库时 graphics/tools/direct/pso_seed.py 跨文件按行去重合并）；拉不到只记一行、照常卸
pso_pull() { local d=${S2A_PSO_SEED_DIR:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/pso_seed} p n=0
  dcp 60 device info files --device "$SW_DEVICE" --domain-type appDataContainer --domain-identifier "$B" --subdirectory Documents/wire --json-output "$T/wire.json" > /dev/null 2>&1
  for p in $(python3 -c "
import json, re, sys
try: fs = json.load(open(sys.argv[1]))['result']['files']
except Exception: fs = []
for f in fs:
    m = re.fullmatch(r'([0-9A-Fa-f]{16})/pso_user\.tsv', f.get('relativePath', ''))
    if m: print(m.group(1))" "$T/wire.json"); do
    rm -f "$T/pso.tsv"; dcp 60 device copy from --device "$SW_DEVICE" --domain-type appDataContainer --domain-identifier "$B" --source "Documents/wire/$p/pso_user.tsv" --destination "$T/pso.tsv" > /dev/null 2>&1
    [ -s "$T/pso.tsv" ] && mkdir -p "$d/$p" && mv "$T/pso.tsv" "$d/$p/${B}_$(date +%m%d%H%M%S)_卸前.tsv" && n=$((n + 1))
  done
  echo "卸前拉回管线种子来源：${n} 份 pso_user.tsv → pso_seed/"; }
source "$TOOLS/devlock.sh"
devlock_acquire "卸载 ${B}（${DEVNAME}）" 300 || { echo "【红】等不到 ${DEVNAME} 的设备锁" >&2; exit 1; }
trap 'devlock_release; rm -rf "$T"' EXIT
installed; r=$?
[ $r = 2 ] && { echo "【红】${DEVNAME}：查已装 App 失败（devicectl）" >&2; exit 1; }
[ $r = 1 ] && { echo "${DEVNAME} 上没装 ${B}，不用卸"; exit 0; }
pso_pull
dcp 120 device uninstall app --device "$SW_DEVICE" "$B" > "$T/u.log" 2>&1 || { echo "【红】${DEVNAME}：卸载 $B 失败：$(tail -1 "$T/u.log")" >&2; exit 1; }
installed; [ $? = 1 ] || { echo "【红】${DEVNAME}：卸载命令返回成功，但 $B 还在" >&2; exit 1; }
echo "已卸载 ${DEVNAME} 上的 ${B}"
