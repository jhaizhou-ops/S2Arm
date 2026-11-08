#!/bin/bash
# 真机现场一把锁（总指挥 11-02：取证脚本只在起局那一步拿设备锁，xcui 点按 / 实时通道 KEY 在锁外，同机别的局趁空起别的 App 把被测 App 挤到后台，复测白跑）：
#   tools/dev_scene.sh <设备> <持锁说明> [上限秒] -- <命令…>
#   整段现场（起局 → 点按 / KEY / 截图 → 收局）放在同一把设备锁里：先选定设备（tools/devices.sh s2a_device），再取锁（tools/devlock.sh），命令在锁内跑，命令退出才放锁。
#   锁可重入：命令里再调 tools/dev_run.sh、tools/xcui/run.sh 等自己取锁的工具，沿用这一把（SW_DEVLOCK_HELD 随环境传下去），不会自己等自己。
#   同一台机上的多个现场按设备锁排队，一个现场跑完下一个才起。命令里可用 SW_DEVICE（devicectl 用的设备号）、DEVNAME。S2A_DEVICE_OWN=1 照常透传（自有设备，如 Duo）。
#   退出码：命令的退出码；用法错 2；选不到设备 / 取不到锁 1
set -u
TOOLS=$(cd "$(dirname "$0")" && pwd)
dev=${1:-}; owner=${2:-}; [ $# -ge 2 ] && shift 2 || set --
max=; if [ $# -gt 0 ] && [ "$1" != -- ]; then max=$1; shift; fi
[ "${1:-}" = -- ] && shift
[ -n "$dev" ] && [ -n "$owner" ] && [ $# -gt 0 ] || { echo "用法：tools/dev_scene.sh <设备> <持锁说明> [上限秒] -- <命令…>" >&2; exit 2; }
source "$TOOLS/devices.sh"; s2a_device "$dev" > /dev/null || exit 1
source "$TOOLS/devlock.sh"; devlock_acquire "$owner" ${max:+"$max"} || exit 1
trap devlock_release EXIT
"$@"
