#!/bin/bash
# 工作盘准入闸（11-06 总指挥：各线手工起的真机 / 录帧 / 回放活不能靠自觉，在共用入口统一套 tools/disk_admit.py）：
#   入口脚本开头 source 本文件，再调 disk_admit_gate <类别> <名> <实测目录> "$0" "$@"：
#   还没在准入里（S2A_DISK_HELD 空）就经 disk_admit.py 重起自己——排到才往下走，余量不够排队；结束按实测目录实际大小记成这个名字下次的预计。
#   写的不在本机工作盘上（远端主机上的 dev_run、录帧写内置盘）→ disk_admit.py --work-only 直接跑、不记账。
#   S2A_DISK_HELD 由 disk_admit.py run 给子进程设（11-06：闸自己先设会让 run 当成外层已预留、不记账）。
#   已在准入里（外层已排到，或单测给 S2A_DISK_HELD=1）直接返回；S2A_DISK_ADMIT=off 由 disk_admit.py 打【黄】放行。
disk_admit_gate() {
  [ -n "${S2A_DISK_HELD:-}" ] && return 0
  local cat=$1 name=$2 measure=$3; shift 3
  local da; da=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/disk_admit.py
  [ -f "$da" ] || { echo "【红】工作盘准入：找不到 ${da}" >&2; return 0; }
  exec python3 "$da" run --work-only --cat "$cat" --name "$name" --measure "$measure" -- bash "$@"
}
