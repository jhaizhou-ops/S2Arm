#!/bin/bash
# 列车合入对账（tools/merge_reconcile.py）：用 10-30 两个真实例子做正反对照：bash tests/merge_reconcile_test.sh
# 门禁覆盖：tools/merge_reconcile.py tests/fixtures/merge_reconcile/
#   #1000：列车合入 faefcc3bc（main 合并提交 27d5c7a8c），PR 头 58402ae25 只是作者合 main 的合并提交（union 段落多一个空行）→ merged
#   #1002：列车合入旧版 46ac320ed（main 合并提交 c89ee6e47），之后 4 个提交没合 → partial
#   夹具：两个 PR 头不在 main 上的那部分提交打成 bundle（前置提交都在 main 历史里）；期望值取自 train.log 合入记录与 git log，不取自被测工具
set -u
H=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/merge_reconcile_test.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }

git clone -q --shared --no-checkout "$H" "$T/r" || { echo "不通 克隆本仓库"; exit 1; }
for p in 1000 1002; do
    git -C "$T/r" fetch -q "$H/tests/fixtures/merge_reconcile/pr$p.bundle" "refs/fx/pr$p:refs/fx/pr$p" \
        || { echo "不通 读夹具 pr$p.bundle（前置提交不在本仓库历史里？浅克隆跑不了本单测）"; exit 1; }
done
R() { python3 "$H/tools/merge_reconcile.py" --repo "$T/r" "$@"; }
F() { python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d[sys.argv[2]] if sys.argv[2] != "outstanding" else " ".join(sorted(d["outstanding"])))' "$1" "$2"; }

M=c89ee6e4764125d5ef803df91a4a013cb9fae997    # 10-30 05:14 合入 #1002 的 main 合并提交（此时 #1000 也已合入）
o=$(R 1000 refs/fx/pr1000 --main $M)
ck "① #1000 头只是合 main 的合并提交 → merged（实得 $(F "$o" state)）" '[ "$(F "$o" state)" = merged ]'
ck "① #1000 合入的提交 = faefcc3bc（main 合并提交 27d5c7a8c）" '[ "$(F "$o" merged)" = faefcc3bcfca22bece9c86a84cbc80c706ef6952 ] && [ "$(F "$o" main_merge)" = 27d5c7a8c36890cc17abee41a5397baabc12a24b ]'

o=$(R 1002 refs/fx/pr1002 --main $M)
ck "② #1002 之后还有提交没合 → partial（实得 $(F "$o" state)）" '[ "$(F "$o" state)" = partial ]'
ck "② #1002 合入的提交 = 46ac320ed" '[ "$(F "$o" merged)" = 46ac320edbc85bf15a9117fb7a790654f4f8274c ]'
want="171ed1176e1af1f53f70bf0536a2b9e7704ed36f 4c7b0bac0a2bfe025e0b2755b3d3b693b911740c 91776d219b17f9466827961e00b0f8ea9265b354 ec084b38da1fb461e5a70d73b48b38c86ce300e4"
ck "② #1002 没合的恰好是 4 个提交（91776d219 ec084b38d 4c7b0bac0 171ed1176）" '[ "$(F "$o" outstanding)" = "$want" ]'

# 反证：两支合入之前的 main，都判「没合过」
o=$(R 1000 refs/fx/pr1000 --main 8d4bbb2cd6a16362086c5cb5f167dc1e90161856)   # 27d5c7a8c 的第一个父
ck "③ #1000 在合入前的 main 上 → none（实得 $(F "$o" state)）" '[ "$(F "$o" state)" = none ]'
o=$(R 1002 refs/fx/pr1002 --main fcb019d7843609dae8079e8f679b9de30c671605)   # c89ee6e47 的第一个父
ck "③ #1002 在合入前的 main 上 → none（实得 $(F "$o" state)）" '[ "$(F "$o" state)" = none ]'

# 正对照：在 #1000 头上再叠一个不改内容的合并提交（树 = 按仓库规则自动合并的结果）→ 仍是 merged
auto=$(git -C "$T/r" -c attr.tree=$M merge-tree --write-tree refs/fx/pr1000 $M | head -1)
honest=$(git -C "$T/r" -c user.name=t -c user.email=t@t commit-tree "$auto" -p refs/fx/pr1000 -p $M -m 'plain merge')
o=$(R 1000 "$honest" --main $M)
ck "④ 再叠一个不改内容的合并提交 → 仍 merged（实得 $(F "$o" state)）" '[ "$(F "$o" state)" = merged ]'
# 反证：合并提交里手改过内容就不算「只是合 main」：同一位置叠一个多了文件的合并提交 → partial
tree=$auto
blob=$(printf 'evil\n' | git -C "$T/r" hash-object -w --stdin)
git -C "$T/r" read-tree "$tree" && git -C "$T/r" update-index --add --cacheinfo 100644,"$blob",evil_merge.txt
t2=$(git -C "$T/r" write-tree)
evil=$(git -C "$T/r" -c user.name=t -c user.email=t@t commit-tree "$t2" -p refs/fx/pr1000 -p $M -m 'merge with hand edit')
o=$(R 1000 "$evil" --main $M)
ck "⑤ 合并提交手改了内容（多一个文件）→ partial（实得 $(F "$o" state)）" '[ "$(F "$o" state)" = partial ]'

[ $bad = 0 ] && echo "merge_reconcile 单测全过" || { echo "merge_reconcile 单测有不通"; exit 1; }
