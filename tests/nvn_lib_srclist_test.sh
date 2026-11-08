#!/bin/bash
# 门禁覆盖：graphics/nvn/Makefile
# libnvn / libglx 随源文件清单重建（11-05 合入运维线）：门禁常驻工作树跨批增量编，某批分支删 / 改名一个源文件后，余下源都比库旧，
#   库不重建、旧库里留着已删文件的目标文件 → 偶发「Undefined symbols」（runtime/gate.sh 组 nvn_rec_cover 构建失败 12 次，干净重跑就绿）。
# 期望（按 make 规则手写，只用 make -q 问「要不要重建」，不真编）：
#   ① 库比源 / 头 / 清单戳都新 → make -q 退 0（不用重建）
#   ② 同样的库，清单少一个源文件（模拟某批删了它）→ make -q 退 1（要重建）；修前没有清单戳 → 退 0（红）
#   ③ 清单不变再问 → 退 0（内容不变不改写戳，不白编）
set -u
H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d "${TMPDIR:-/tmp}/nvn_srclist_XXXXXX"); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if [ "$2" = "$3" ]; then echo "通 $1"; else echo "不通 $1：期望 $2 → 真结果 $3"; bad=1; fi; }
O=$T/out
printf 'print-srcs: ; @echo $(SRCS)\nprint-gen: ; @echo $(AA_MSLH) $(AA_LUTH) $(GENH)\n' > "$T/print.mk"
SR=$(make -s -C "$H/graphics/nvn" -f Makefile -f "$T/print.mk" print-srcs OUT="$O")
[ -n "$SR" ] || { echo "不通 取不到 SRCS"; exit 1; }
LESS=$(tr ' ' '\n' <<< "$SR" | grep . | sed '$d' | tr '\n' ' ')
q() { make -q -C "$H/graphics/nvn" "$O/mac/libnvn.a" OUT="$O" "$@" > /dev/null 2>&1; echo $?; }
q > /dev/null   # 头一次解析写出清单戳
for g in $(make -s -C "$H/graphics/nvn" -f Makefile -f "$T/print.mk" print-gen OUT="$O"); do mkdir -p "$(dirname "$g")"; : > "$g"; done   # 生成头（AA 着色器嵌入、曲面细分）也是库的依赖：先建好，只看源清单这一个变量
mkdir -p "$O/mac"; sleep 1; touch "$O/mac/libnvn.a"
ck "① 库比源 / 头 / 清单戳都新 → 不用重建" 0 "$(q)"
sleep 1
ck "② 清单少一个源文件（$(tr ' ' '\n' <<< "$SR" | grep . | tail -1)）→ 要重建" 1 "$(q SRCS="$LESS")"
mkdir -p "$O/mac"; sleep 1; touch "$O/mac/libnvn.a"
ck "③ 清单不变再问 → 不用重建（戳内容没变不改写）" 0 "$(q SRCS="$LESS")"
[ $bad = 0 ] && echo "nvn_lib_srclist 单测全过" || { echo "nvn_lib_srclist 单测有不通"; exit 1; }
