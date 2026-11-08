#!/bin/bash
# 出包·直连管线种子表阶段：pack/stage_direct_seed.sh <款>（审计 #1534 P1-54 B3，照 pack/stage_direct_gk.sh 从直连库阶段拆出）
# 出 shaders/direct/pso_manifest.tsv（管线预建种子表，nvn_mtl.m warm_worker 起局后台预建）：来源 = 跑局知识快照的 seen.tsv（graphics/tools/direct/run_knowledge.py，
#   读 pso_seed/<程序号>/ 或 S2A_PSO_SOURCES），按直连库实际出成的键（shaders/direct/keys.tsv）滤，graphics/tools/direct/pso_seed.py 生成。只写这一张表，几秒。
# 为什么单独一段：种子表只决定首局预建哪些管线，不改任何着色器；跑一局只多几行 R 行时不该让直连库阶段整段重跑（原先种子来源根本不进键：知识变了、包里还是旧表）。
#   键 = 直连库阶段键 + seen.tsv 内容 + 生成代码（pack/stage_inputs/direct_seed.tsv「入」）；与现行 .stage_direct_seed 相同就跳过。快照随产物根留档（knowledge/seed/seen.tsv）。
# 种子表是锦上添花（审计 #1592 P1-100）：宿主缺这张表只是不预建（nvn_mtl.m warm_paths 打一行红、连本机 pso_user.tsv 也不预建），游戏照常跑、首遇现编。
#   生成失败（快照 / 量键长 / pso_seed.py 任一步）不再让整次刷新停（原先 exit 1 → pack/refresh.sh 停、这一次包不出）：打一行【黄】写明缺了什么，
#   现行没有种子表就放一张只有表头的空表（= 没有来源时的正常产物，宿主照常预建本机清单），不记本阶段键（下次刷新重试）、照常提交，退出 0
# 配置档维护过种子表的（direct_lib.json pso_seed=profile，直连库阶段原样带了）、Vulkan / OpenGL / 安卓 / 运行时现编空库（没有 pso_seed=gen）：不生成，跳过、现行不动。
set -u
G=${1:?款}; H=$(cd "$(dirname "$0")" && pwd); R=$(cd "$H/.." && pwd); source "$H/roots.sh"; source "$H/stage_keyfiles.sh"; stage_deps_on || exit 1; SELF=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")   # 实际读入进键（pack/stage_keyfiles.sh）
CUR=$(root_cur "$G"); [ -n "$CUR" ] || { echo "【红】$G 没有现行产物根"; exit 1; }
PY=${S2A_PYTHON:-${S2A_PY:-python3}}
MODE=$("$PY" -c 'import json,sys
try: print(json.load(open(sys.argv[1], encoding="utf-8")).get("pso_seed", ""))
except OSError: print("")' "$CUR/shaders/direct/direct_lib.json") || { echo "【红】$G 读不懂 shaders/direct/direct_lib.json"; exit 1; }
[ "$MODE" = gen ] || { echo "🟡 $G 种子表不用生成（$([ "$MODE" = profile ] && echo 配置档维护过、直连库阶段原样带了 || echo 没有要生成的 NVN Metal 直连库)），跳过"; exit 0; }
[ -f "$CUR/shaders/direct/keys.tsv" ] || { echo "【红】$G 直连库要生成种子表却没有 shaders/direct/keys.tsv"; exit 1; }
# soft <原因>：种子表出不来——现行里放空表（已有就留着）、不记键，照常提交、退出 0（W 未开时先开）
soft() {
  echo "【黄】$G 管线种子表这次没生成：$1；包照常出，缺的是首局管线预建（首遇现编），下次刷新重试；包里那张空表的表头记着同一原因"
  [ -n "${W:-}" ] || { TAG=$(root_tag "$G" "sd-fail"); W=$(root_begin "$G" "$TAG") || exit 1; }
  local D=$W/shaders/direct
  [ -f "$D/pso_manifest.tsv" ] || printf '# Prewarm seed list: empty (generation failed at packing time: %s); pipelines compile at their first use\n' "$(tr -d '\t\n' <<< "$1" | cut -c1-200)" > "$D/pso_manifest.tsv" || { root_abort "$G" "$TAG"; exit 1; }
  rm -f "$W/.stage_direct_seed" "$W/.stage_direct_seed.deps"
  ROOT_REPLAY='shaders/direct/pso_manifest.tsv knowledge/seed .stage_direct_seed .stage_direct_seed.deps' root_commit "$G" "$TAG" || exit 1
  exit 0
}
W=
KND=$(mktemp -d "${TMPDIR:-/tmp}/s2a_seed.XXXXXX") || { echo "【红】$G 建不了跑局知识快照的临时目录"; exit 1; }
trap 'rm -rf "$KND"' EXIT
"$PY" "$R/graphics/tools/direct/run_knowledge.py" "$KND/t" "$CUR" > "$KND/log" 2>&1 || soft "跑局知识快照出不来（graphics/tools/direct/run_knowledge.py：$(tail -1 "$KND/log" | cut -c1-200)）"
KT=$(stage_files_key direct_seed "$R") || exit 1   # 生成代码键：pack/stage_inputs/direct_seed.tsv「入」的文件（pso_seed.py、管线键布局、本脚本）
K=$(printf '%s\n%s\n%s\n' "$(cat "$CUR/.stage_direct" 2> /dev/null)" "$(shasum -a 256 < "$KND/t/seen.tsv" | cut -c1-64)" "$KT" | shasum -a 256 | cut -c1-16)
KB=$K; K=$(stage_deps_key "$CUR" direct_seed "$KB" "$SELF") || exit 1
root_stage_done "$CUR" direct_seed "$K" && { echo "🟢 $G 现行已是管线种子表 ${K}，跳过"; exit 0; }
TAG=$(root_tag "$G" "sd-${K:0:8}"); W=$(root_begin "$G" "$TAG") || exit 1
SK=$("$PY" "$R/graphics/tools/direct/pso_layout.py" skey-size) || soft "量不出管线键字节数（graphics/tools/direct/pso_layout.py）"
rm -rf "$W/knowledge/seed"; mkdir -p "$W/knowledge/seed" && cp "$KND/t/seen.tsv" "$W/knowledge/seed/seen.tsv" || { echo "【红】$G 跑局知识快照拷不进工作根"; root_abort "$G" "$TAG"; exit 1; }
D=$W/shaders/direct
# pso_seed.py 的第三个参数（着色器表）只为调用口径保留、不读
GEN=$("$PY" "$R/graphics/tools/direct/pso_seed.py" "$D/pso_manifest.tsv" "$D/keys.tsv" "$D/shader_map.tsv" "$SK" "$W/knowledge/seed/seen.tsv" 2>&1) || soft "pso_seed.py 失败：$(tail -1 <<< "$GEN" | cut -c1-200)"
stage_deps_save "$W" direct_seed "$KB" "$SELF" > "$W/.stage_direct_seed" || { root_abort "$G" "$TAG"; exit 1; }
ROOT_REPLAY='shaders/direct/pso_manifest.tsv knowledge/seed .stage_direct_seed .stage_direct_seed.deps' root_commit "$G" "$TAG" || exit 1
echo "🟢 $G ${GEN%%；*}（现行 → $(basename "$(root_cur "$G")")）"
