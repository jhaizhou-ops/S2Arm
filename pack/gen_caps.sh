#!/bin/bash
# 生成包内能力清单 s2a_caps.tsv（宿主 runtime/src/caps.c 读：1 = 开、0 = 显式关；启动环境变量与用户在设置里改过的开关都优先于清单）：pack/gen_caps.sh <款> <产物根> <输出文件> [--all-caps]
#   缺省 = 发布包（jhz 10-29 07:0x 全能力出包「默认开、强信号才关」，口径 docs/能力卡_数据口径.md 第 7 节）：fps60 / widen 两键由 tools/caps_policy.py decide 定——
#     命中强信号（docs/名单_能力强信号/、名单_60帧 逻辑速度红）→ 0；本包有任一来源（宽屏表 / 社区补丁 / 通用宽屏改写 / 帧率表）→ 1；一个来源都没有 → 0。不在这里另写判定。
#   --all-caps = 给 jhz / 真机测试的包：同一份来源定义，不看登记的强信号，有来源即开。
#   直连 / 手柄 / 马达 / 陀螺仪是宿主通用能力，两种模式都写 1。
set -u
#   --both <--all-caps 输出文件>：一次判定出两份（pack/stage_caps.sh 用；引擎推导要读 RomFS 文件头，两种口径共用一次，11-03 火纹原先两次各 160 秒）
G=${1:?款}; CUR=${2:?产物根}; OUT=${3:?输出文件}; MODE=${4:-}; OUT_ALL=
[ "$MODE" = --both ] && OUT_ALL=${5:?--both 要第二个输出文件}
R=$(cd "$(dirname "$0")/.." && pwd)
D=${S2A_DUAL:-1}; [ "$D" = 1 ] && DR="直连可用" || DR="仅通用（S2A_DUAL=0）"
# 平台口径（F7 #1574）：S2A_CAPS_TARGET 优先（pack/stage_caps.sh 传），缺省按 S2A_PACK_PLAT 推；清单首行 plat<TAB><目标>，
#   安卓打包（android/tools/make_pack.py）只收 plat android 头的清单——把苹果产物根的清单打进安卓包立刻报红（#996 防重演）
TGT=${S2A_CAPS_TARGET:-}; [ -n "$TGT" ] || { [ "${S2A_PACK_PLAT:-ios}" = android ] && TGT=android || TGT=apple; }
# S2A_CAPS_REPO：单测钩子（合成登记表的仓库）
LINES=$(python3 "$R/tools/caps_policy.py" decide "${S2A_CAPS_REPO:-$R}" "$CUR" $MODE --target "$TGT")
n=0
while IFS=$'\t' read -r F FR W WR FD; do
n=$((n + 1)); M=$MODE; O=$OUT
[ "$MODE" = --both ] && { [ $n = 1 ] && M= || { M=--all-caps; O=$OUT_ALL; }; }
[ -n "${F:-}" ] || { echo "【红】$G 能力开关判定失败（tools/caps_policy.py decide，多半是 docs/名单_能力强信号/ 有不认的信号）"; exit 1; }
[ "$M" = --all-caps ] && HEAD="--all-caps 出包：有来源即开、不看强信号" || HEAD="发布包：60 帧默认开、强信号才关；满屏默认关、真机验过或有补丁才开（tools/caps_policy.py）"
printf 'plat\t%s\n# 包内能力清单（%s）\n# 格式：<能力>\\t<值>\\t# <原因>（1 = 开，0 = 显式关）；优先级：启动环境 > Settings.bundle（用户改过的设置）> 本文件\nwiden\t%s\t# %s\nfps60\t%s\t# %s\ndirect\t%s\t# %s\ngyro\t1\t# 宿主通用能力\nhaptics\t1\t# 宿主通用能力\n' \
  "$TGT" "$HEAD" "$W" "$WR" "$F" "$FR" "$D" "$DR" > "$O"
# 引擎通用全引擎档（没有帧率表 / 社区补丁 / Unity·UE 推导的款，tools/caps_policy.py 第 5 列）：宿主读到 fps60_display 1 且 60 帧开着就放开出图间隔（runtime/src/caps.c，同 present display）
if [ "${FD:-0}" = 1 ]; then printf 'fps60_display\t1\t# 引擎通用：放开出图间隔（全引擎，同局 A/B 判红才关）\n' >> "$O"; fi
done < <(printf '%s\n' "$LINES")
want=1; [ "$MODE" = --both ] && want=2
[ "$n" = "$want" ] || { echo "【红】$G 能力开关判定失败（tools/caps_policy.py decide 应出 $want 行、实得 $n 行，多半是 docs/名单_能力强信号/ 有不认的信号）"; exit 1; }
