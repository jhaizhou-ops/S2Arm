#!/bin/bash
# 普查补丁局（11-03 总指挥：补丁修复不计入一次成功，总表另列「补丁包修复」）：bash tools/census/patch_run.sh <源（解包目录 / 已出包目录）> <主局输出目录> <程序号>
#   CENSUS_PATCH_DIR=<补丁根> 下有 <程序号>/patch.tsv、且主局（<主局输出目录>/结果.tsv）按总表口径一次成功≠是 → 带 S2A_PATCH_DIR 同一个源再跑一局
#   one_game.sh 到 <主局输出目录>_patch（自己的产物根 <主局输出目录>_patch/roots：[code] 段在出包改写时打、[data] / 能力段在宿主装载时生效，不碰共享根与主局的根）；
#   其余情况什么都不做。census.py row 经 CENSUS_PATCH_RES=<主局输出目录>_patch/结果.tsv 记那一列。
#   起因：激战前锋复判局没给 S2A_PATCH_DIR，宿主找 ~/Documents/S2A/patches 落空，[data] 补丁根本没装，补丁修复的款永远判不出。
#   环境照主局（调用方同一行 env 带进来）；补丁局不再补跑原生档（QT_NATIVE_TIER=0）。CENSUS_ONE_GAME 可换单款流水线（单测用）。退出码：0 = 没跑或跑完（结论看结果表），2 = 参数问题
set -u
SRC=${1:?源}; RD=${2:?主局输出目录}; K=${3:?程序号}
R=$(cd "$(dirname "$0")/../.." && pwd); PY=${PY:-python3}
P=${CENSUS_PATCH_DIR:-}
[ -n "$P" ] && [ -f "$P/$K/patch.tsv" ] || exit 0
os=$("$PY" "$R/tools/census/census.py" oneshot_res "$K" "$RD/结果.tsv")
[ "$os" = 是 ] && exit 0
echo "补丁局：$K 主局一次成功 ${os}，有补丁 $P/$K/patch.tsv → 带补丁另跑一局到 ${RD}_patch"
S2A_PATCH_DIR=$P QT_NATIVE_TIER=0 bash "${CENSUS_ONE_GAME:-$R/tools/quicktest/one_game.sh}" "$SRC" "${RD}_patch"
echo "补丁局：$K 结束 rc=$?"
exit 0
