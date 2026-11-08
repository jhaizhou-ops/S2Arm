#!/bin/bash
# 看板直连口径里程碑证据判定单测（tools/board.py direct_run / mac_direct，约 1 秒）：bash tests/board_m5_test.sh
# 期望按 host.log 内容手写：
#   ① 「图形模式：直连（依据 包里带本翻译链的直连库…」+ MARK → 零配置、到 MARK、前端 NVN
#   ② 依据「环境变量 S2A_GFX=direct」→ 不算零配置（mac_direct 不认）
#   ③ 「直连：Vulkan 款」→ 前端 Vulkan
#   ④ 通用局 / 没有图形模式行 → 不是直连局（None）
#   ⑤ mac_direct 只认 milestones/M5_*/<款>/ 里零配置且到 MARK 的，取最新一份
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mk() { mkdir -p "$(dirname "$1")"; printf '%s\n' "$2" > "$1"; }
mk $T/m/M5_a/acnh/host.log $'[s2a] 图形模式：直连（依据 包里带本翻译链的直连库（b-c407c4b309b7）；程序号 01006F8002326000）\nS2A 标记 MARK：帧 900'
mk $T/m/M5_a/mk8d/host.log $'[s2a] 图形模式：直连（依据 环境变量 S2A_GFX=direct；程序号 0100152000022000）\nS2A 标记 MARK：帧 900'
mk $T/m/M5_a/hades/host.log $'[s2a] 图形模式：直连（依据 包里带本翻译链的直连库（b-1）；程序号 0100535012974000）\n[s2a] 直连：Vulkan 款，vk* 导入解析\nS2A 标记 MARK：帧 4770'
mk $T/m/M5_a/d2r/host.log $'[s2a] 图形模式：通用（依据 缺省；程序号 0100726014352000）\nS2A 标记 MARK：帧 900'
mk $T/m/M5_a/botw/host.log $'[s2a] 图形模式：直连（依据 包里带本翻译链的直连库（b-1）；程序号 01007EF00011E000）'
S2A_MILESTONES=$T/m python3 - "$H" "$T/m" <<'PY'
import sys, os; sys.path.insert(0, sys.argv[1] + '/tools'); import board
board.HD = sys.argv[2] + '/没有健康表'; m = sys.argv[2]; bad = 0
def ck(name, got, want):
    global bad; ok = got == want; bad |= not ok; print(('通 ' if ok else '不通 ') + f'{name}：期望 {want} → 真结果 {got}')
ck('① 零配置直连 + MARK', board.direct_run(f'{m}/M5_a/acnh/host.log'), (True, True, 'NVN'))
ck('② 环境变量强制直连不算零配置', board.direct_run(f'{m}/M5_a/mk8d/host.log'), (False, True, 'NVN'))
ck('③ Vulkan 前端', board.direct_run(f'{m}/M5_a/hades/host.log'), (True, True, 'Vulkan'))
ck('④ 通用局不是直连局', board.direct_run(f'{m}/M5_a/d2r/host.log'), None)
ck('⑤ mac_direct：acnh 认、mk8d（强制）不认、d2r（通用）不认、botw（没 MARK）不认',
   [bool(board.mac_direct(g)) for g in ('acnh', 'mk8d', 'd2r', 'botw')], [True, False, False, False])
sys.exit(bad)
PY
[ $? = 0 ] && echo "board_m5 单测全过" || { echo "board_m5 单测有不通"; exit 1; }
