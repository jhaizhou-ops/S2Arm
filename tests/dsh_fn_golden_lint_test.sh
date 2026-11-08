#!/bin/bash
# 门禁覆盖：graphics/tools/direct/tests/dsh_fn_golden.jsonl .gitattributes tools/golden_lint.py
# 逐函数金样 dsh_fn_golden.jsonl 设了 merge=union（11-05 总指挥：各支只往末尾追加用例，tess-mode-gl 三次、#1469 一次撞冲突被退回）。
#   union 合并在两支改到相邻行时两边都留，可能留下「同一用例两个期望」或坏行；本测核合并结果没被合坏。
# 期望（按规则手写，不跑被测实现推导）：
#   ① 真金样：每行合法 JSON、有 fn / args / want，同一 (fn, args) 没有两个不同的 want → 通（完全相同的重复行无害，只计数不报红）
#   ② 临时仓库实演：属性 merge=union，两支把同一行 want 各改成 1 / 2 → git merge 不冲突、两行都在 → 检查报红，红行带「文件:行号:」
#   ③ 坏行（截断的 JSON）→ 报红并带行号
set -u
H=$(cd "$(dirname "$0")/.." && pwd); bad=0
ck() { if eval "$2"; then echo "🟢 $1"; else echo "🔴 $1"; bad=1; fi; }
T=$(mktemp -d "${TMPDIR:-/tmp}/t_golden_lint.XXXXXX"); trap 'rm -rf "$T"' EXIT
G=graphics/tools/direct/tests/dsh_fn_golden.jsonl
o=$(cd "$H" && python3 tools/golden_lint.py "$G" 2>&1); rc=$?
ck "① 真金样合法、无矛盾期望（$(tail -1 <<< "$o")）" '[ $rc = 0 ]'
ck "① 真金样已设 merge=union" '[ "$(git -C "$H" check-attr merge -- "$G" | sed "s/^.*: merge: //")" = union ]'
R=$T/r; mkdir -p "$R/d" && cd "$R" && git init -q && git config user.email t@t && git config user.name t
echo 'd/g.jsonl merge=union' > .gitattributes
printf '%s\n' '{"fn": "a", "args": [1], "want": {"ok": 0}}' '{"fn": "b", "args": [2], "want": {"ok": 0}}' > d/g.jsonl
git add -A && git commit -qm base && B0=$(git branch --show-current) && git branch x
sed -i.bak 's/"fn": "a", "args": \[1\], "want": {"ok": 0}/"fn": "a", "args": [1], "want": {"ok": 1}/' d/g.jsonl && rm d/g.jsonl.bak && git commit -qam one
git switch -q x && sed -i.bak 's/"fn": "a", "args": \[1\], "want": {"ok": 0}/"fn": "a", "args": [1], "want": {"ok": 2}/' d/g.jsonl && rm d/g.jsonl.bak && git commit -qam two
git merge -q --no-edit "$B0" > /dev/null 2>&1; mrc=$?
o2=$(python3 "$H/tools/golden_lint.py" d/g.jsonl 2>&1); rc2=$?
ck "② union 合并不冲突（rc=${mrc}）且两个期望都留下（$(grep -c '"fn": "a"' d/g.jsonl) 行）" '[ $mrc = 0 ] && [ "$(grep -c "\"fn\": \"a\"" d/g.jsonl)" = 2 ]'
ck "② 检查报红、红行带 d/g.jsonl:行号:（$(head -1 <<< "$o2")）" '[ $rc2 != 0 ] && grep -qE "^d/g.jsonl:[0-9]+: " <<< "$o2"'
printf '%s\n' '{"fn": "c", "args": [3], "want": {"ok": 0}}' '{"fn": "c", "args": [' > "$T/bad.jsonl"
o3=$(python3 "$H/tools/golden_lint.py" "$T/bad.jsonl" 2>&1); rc3=$?
ck "③ 截断行报红并带行号 2（$(head -1 <<< "$o3")）" '[ $rc3 != 0 ] && grep -qE "bad.jsonl:2: " <<< "$o3"'
[ $bad = 0 ] && echo "dsh_fn_golden_lint 单测全过"; exit $bad
