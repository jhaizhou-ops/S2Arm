#!/bin/bash
# 直连库「未守卫的新系统 API」棘轮：按系统下限（iOS 18 / macOS 15）编译时，每个（平台、文件、符号）的告警次数只许减不许增，基线见 tools/avail_baseline.txt。
# 现有的都是 Metal 4 专有类型 / 枚举，或只在 !g_m3 分支里发的消息（10-28 逐处核过）；新增一处就要先确认它不会在 Metal 3 设备上执行，
#   要么包 if (@available(macOS 26.0, iOS 26.0, *))，要么确属 Metal 4 分支再同笔改基线（-u）。setReductionMode 那次就是没守卫、老系统必崩
# 用法：bash graphics/nvn/tools/avail_count.sh [-u]（-u 用当前结果重写基线）
cd "$(dirname "$0")/.." || exit 2
cur=$(make -s avail | sort | uniq -c | awk '{print $1, $2, $3, $4}') || exit 2
[ -n "$cur" ] || { echo "可用性检查没出结果（编译命令坏了？）"; exit 2; }
# 编不过的文件告警数不出来，计数会少、棘轮绿着失效（11-01：干净检出缺生成头 gal_tess_msl.h，300 处读成 12 处照样过）
err=$(echo "$cur" | awk '$4 == "编译出错" {print "  " $2 " " $3}'); [ -z "$err" ] || { echo "可用性检查编译出错，计数不可信："; echo "$err"; exit 2; }
if [ "${1:-}" = -u ]; then echo "$cur" > tools/avail_baseline.txt; echo "基线已写：$(echo "$cur" | awk '{s+=$1} END {print s}') 处"; exit 0; fi
bad=$(echo "$cur" | awk 'NR == FNR {b[$2 " " $3 " " $4] = $1; next} $1 > (b[$2 " " $3 " " $4] + 0) {printf "  %s %s %s：%d 处（基线 %d）\n", $2, $3, $4, $1, b[$2 " " $3 " " $4] + 0}' tools/avail_baseline.txt -)
n=$(echo "$cur" | awk '{s+=$1} END {print s}'); nb=$(awk '{s+=$1} END {print s+0}' tools/avail_baseline.txt)
if [ -n "$bad" ]; then echo "未守卫新系统 API ${n} 处（基线 ${nb}），新增："; echo "$bad"; exit 1; fi
echo "未守卫新系统 API ${n} 处（基线 ≤ ${nb}，没有新增）"
