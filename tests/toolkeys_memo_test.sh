#!/bin/bash
# tool_keys 记忆单测（graphics/tools/shader_pack.sh --tool-keys，10-30 出包线 P4；约 20 秒）：bash tests/toolkeys_memo_test.sh
# 期望（对照 = 关掉记忆照算的 tool_keys，不是被测的记忆本身）：
#   ① 第一次现算并记忆、第二次命中，CS XC 与照算逐字相同；② 记忆键里的环境变量（XLATE_DEBUG）变了 → 现算；③ 无关环境变量（S2A_UNRELATED_NOTE）变了 → 照样命中；
#   ④ compat/tree · gfx · tools 下有未跟踪文件 → 照算、不写记忆（单测在本树 graphics/ 下临时放一个文件，退出即删）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); X=$H/graphics/.toolkeys_memo_test_$$; trap 'rm -rf "$T" "$X"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
SP=$H/graphics/tools/shader_pack.sh
if [ -n "$(git -C "$H" status --porcelain --untracked-files=normal -- compat/tree gfx tools)" ]; then
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
n0=$(ls $T/c 2> /dev/null | wc -l | tr -d ' '); echo x > "$X"
o5=$(run); h5=$(cat $T/how); n1=$(ls $T/c 2> /dev/null | wc -l | tr -d ' ')
ck "④ 有未跟踪文件 → 照算、不写记忆（「${h5}」，记忆 ${n0} → ${n1} 份）" '[ "$o5" = "$ref" ] && grep -q "未提交改动，不记忆" <<< "$h5" && [ "$n0" = "$n1" ]'
[ $bad = 0 ] && echo "toolkeys_memo 单测全过" || { echo "toolkeys_memo 单测有不通"; exit 1; }
