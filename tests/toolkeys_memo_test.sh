#!/bin/bash
# tool_keys 记忆单测（graphics/tools/shader_pack.sh --tool-keys，10-30 出包线 P4；约 20 秒）：bash tests/toolkeys_memo_test.sh
# 期望（对照 = 关掉记忆照算的 tool_keys，不是被测的记忆本身）：
#   ① 第一次现算并记忆、第二次命中，CS XC 与照算逐字相同；② 记忆键里的环境变量（XLATE_DEBUG）变了 → 现算；③ 无关环境变量（S2A_UNRELATED_NOTE）变了 → 照样命中；
#   ④ compat/tree · gfx · tools 下有未跟踪文件 → 照算、不写记忆（在临时克隆里放未跟踪文件，不碰本树：11-09 原先放在本树 graphics/ 下，
#     门禁并行时同一棵树上的 pack/ipa.sh 正好查「树干净」→ 拒绝出包，readonly_rm_test / oneclick_test ⑦⑫ 偶发红的根因）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
SP=$H/graphics/tools/shader_pack.sh
if [ -n "$(git -C "$H" status --porcelain --untracked-files=normal -- compat/tree graphics translator tools)" ]; then
  echo "跳过 ①–③：本树 compat/tree · gfx · tools 有未提交改动（记忆按设计不生效）；只测 ④"; dirty=1; else dirty=0; fi
ref=$(S2A_TOOLKEYS_MEMO=0 bash "$SP" --tool-keys 2> /dev/null)
run() { env "$@" S2A_TOOLKEYS_CACHE=$T/c bash "$SP" --tool-keys 2> $T/how; }
if [ $dirty = 0 ]; then
  o1=$(run); h1=$(cat $T/how); o2=$(run); h2=$(cat $T/how)
  ck "① 现算并记忆 → 命中，结果与照算相同（「${h1}」→「${h2}」）" '[ -n "$ref" ] && [ "$o1" = "$ref" ] && [ "$o2" = "$ref" ] && grep -q 现算并记忆 <<< "$h1" && grep -q 命中记忆 <<< "$h2"'
  o3=$(run XLATE_DEBUG=0); h3=$(cat $T/how)
  ck "② 记忆键里的环境变量变了 → 现算（「${h3}」）" '[ "$o3" = "$ref" ] && grep -q 现算并记忆 <<< "$h3"'
  o4=$(run S2A_UNRELATED_NOTE=unrelated); h4=$(cat $T/how)
  ck "③ 无关环境变量变了 → 照样命中（「${h4}」）" '[ "$o4" = "$ref" ] && grep -q 命中记忆 <<< "$h4"'
fi
# ④ 临时克隆（共享对象、检出本树 HEAD，约 2 秒）+ 本树现行的 shader_pack.sh（被测的是工作区这份）；对照也在同一份克隆、带着未跟踪文件关掉记忆照算
git clone -q --shared --no-checkout "$H" "$T/r" && git -C "$T/r" checkout -q "$(git -C "$H" rev-parse HEAD)" && cp "$SP" "$T/r/graphics/tools/shader_pack.sh" \
  || { echo "不通 ④ 建临时克隆失败"; exit 1; }
echo x > "$T/r/graphics/.toolkeys_memo_test_$$"
ref4=$(S2A_TOOLKEYS_MEMO=0 bash "$T/r/graphics/tools/shader_pack.sh" --tool-keys 2> /dev/null)
n0=$(ls $T/c 2> /dev/null | wc -l | tr -d ' ')
o5=$(env S2A_TOOLKEYS_CACHE=$T/c bash "$T/r/graphics/tools/shader_pack.sh" --tool-keys 2> $T/how); h5=$(cat $T/how); n1=$(ls $T/c 2> /dev/null | wc -l | tr -d ' ')
ck "④ 有未跟踪文件 → 照算、不写记忆（「${h5}」，记忆 ${n0} → ${n1} 份）" '[ -n "$ref4" ] && [ "$o5" = "$ref4" ] && grep -q "未提交改动，不记忆" <<< "$h5" && [ "$n0" = "$n1" ]'
ck "④ 本树没被弄脏（不往仓库里放临时文件）" '[ -z "$(git -C "$H" status --porcelain --untracked-files=normal -- graphics | grep toolkeys_memo_test)" ]'
[ $bad = 0 ] && echo "toolkeys_memo 单测全过" || { echo "toolkeys_memo 单测有不通"; exit 1; }
