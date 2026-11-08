#!/bin/bash
# 出包·直连客体代码表阶段：pack/stage_direct_gk.sh <款>（10-25 从 pack/stage_direct.sh 拆出）
# 出 shaders/direct/guest_key.tsv（客体代码 sha256 前 16 位 → 直连键）：通用模式 Ryujinx 按它把见过的着色器写 seen_shaders.tsv（覆盖率就绪）。
#   来源 = 着色器阶段烘焙出的 shaders/guest_keys.tsv（客体代码 → S2Arm 键）经直连库的 shaders/direct/key_map.tsv 换键。
# 为什么单独一段：它同时要着色器阶段和直连库阶段的产物；拆出来后那两段各算各的键、在 pack/refresh.sh 里并行跑（jhz「一次出完整包」：直连库不再排在通用烘焙后面），
#   这一段只做换键，几秒。键 = 着色器阶段键 + 直连库阶段键；与现行 .stage_direct_gk 相同就跳过。
# Vulkan 款（直连库是 SPIR-V 键，没有 key_map.tsv）与没出直连库的款：没有可换的，跳过、现行不动。
set -u
G=${1:?款}; H=$(cd "$(dirname "$0")" && pwd); source "$H/roots.sh"; source "$H/stage_keyfiles.sh"; stage_deps_on || exit 1; SELF=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")   # 实际读入进键（pack/stage_keyfiles.sh）
CUR=$(root_cur "$G"); [ -n "$CUR" ] || { echo "【红】$G 没有现行产物根"; exit 1; }
[ -f "$CUR/shaders/direct/key_map.tsv" ] || { echo "🟡 $G 直连库没有 key_map.tsv（Vulkan 款或没出直连库），客体代码表跳过"; exit 0; }
K=$(printf '%s\n%s\n' "$(cat "$CUR/.stage_shaders" 2> /dev/null)" "$(cat "$CUR/.stage_direct" 2> /dev/null)" | shasum -a 256 | cut -c1-16)
KB=$K; K=$(stage_deps_key "$CUR" direct_gk "$KB" "$SELF") || exit 1
# 直连库出成、通用兜底不预编的根（着色器键尾 -lazy，pack/refresh.sh C.3）：没有烘焙，也就没有 shaders/guest_keys.tsv。客体代码表只给「通用起手、记覆盖率、就绪再切直连」用
#   （graphics/loop/ShaderPack.cs Seen：包里没有表 = 不记），直连就绪的款用不上：不出表，清掉从上一版根克隆来的旧表（它的键对着旧直连库），记键。
#   10-26 运维线：C.3 合入后这里照旧要求 guest_keys.tsv，NVN 直连款正式出包全红（acnh 停在 direct_gk）
if [[ "$(cat "$CUR/.stage_shaders" 2> /dev/null)" == *-lazy ]]; then
  root_stage_done "$CUR" direct_gk "$K" && [ ! -e "$CUR/shaders/direct/guest_key.tsv" ] && { echo "🟢 $G 现行已是客体代码表 ${K}（兜底不预编，不出表），跳过"; exit 0; }
  TAG=$(root_tag "$G" "gk-${K:0:8}"); W=$(root_begin "$G" "$TAG") || exit 1
  _root_rm "$W/shaders/direct/guest_key.tsv"; stage_deps_save "$W" direct_gk "$KB" "$SELF" > "$W/.stage_direct_gk" || { root_abort "$G" "$TAG"; exit 1; }
  ROOT_REPLAY='shaders/direct/guest_key.tsv .stage_direct_gk .stage_direct_gk.deps' root_commit "$G" "$TAG" || exit 1
  echo "🟢 $G 通用兜底不预编（直连就绪）：不出客体代码表（现行 → $(basename "$(root_cur "$G")")）"; exit 0
fi
[ -f "$CUR/shaders/guest_keys.tsv" ] || { echo "【红】$G 现行产物根没有 shaders/guest_keys.tsv（先出着色器阶段：pack/stage_shaders.sh ${G}）"; exit 1; }
root_stage_done "$CUR" direct_gk "$K" && [ -f "$CUR/shaders/direct/guest_key.tsv" ] && { echo "🟢 $G 现行已是客体代码表 ${K}，跳过"; exit 0; }
TAG=$(root_tag "$G" "gk-${K:0:8}"); W=$(root_begin "$G" "$TAG") || exit 1
# 客体代码 → 直连键：烘焙表的 S2Arm 键经 key_map 换；换不到的（烘焙继承的参考缓存程序、不在并集里的）只计数
GK=$(python3 - "$W/shaders/guest_keys.tsv" "$W/shaders/direct/key_map.tsv" "$W/shaders/direct/guest_key.tsv" <<'PY'
import sys
gk, km, out = sys.argv[1:4]
m = dict(l.rstrip('\n').split('\t')[:2] for l in open(km, encoding='utf-8') if not l.startswith('#') and '\t' in l)
rows, miss = set(), 0
for l in open(gk, encoding='utf-8'):
    if l.startswith('#') or '\t' not in l: continue
    h, k = l.rstrip('\n').split('\t')[:2]
    if k in m: rows.add(f'{h}\t{m[k]}\n')
    else: miss += 1
open(out, 'w', encoding='utf-8').writelines(['# 客体代码 sha256 前 16 位\t键（直连口径）\n'] + sorted(rows))
print(f'{len(rows)} 行，换不到键 {miss} 行')
PY
) || { echo "【红】$G 出客体代码 → 键表失败"; root_abort "$G" "$TAG"; exit 1; }
stage_deps_save "$W" direct_gk "$KB" "$SELF" > "$W/.stage_direct_gk" || { root_abort "$G" "$TAG"; exit 1; }
ROOT_REPLAY='shaders/direct/guest_key.tsv .stage_direct_gk .stage_direct_gk.deps' root_commit "$G" "$TAG" || exit 1
echo "🟢 $G 直连客体代码表：${GK}（现行 → $(basename "$(root_cur "$G")")）"
