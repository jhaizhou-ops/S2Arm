#!/bin/bash
# 门禁覆盖：tools/reglist_merge.py .gitattributes
# 按款登记表合并器单测（11-06 普查收批 c1105_mc_flk1 / flk2 同款冲突退回）：临时仓库登记合并器，两支各改同一款文件依次合进 main。
# 期望（按规则手写）：
#   ① 两批同日登记同一款不同结论 → 两次合并都不冲突，最终是后合的那支（后一批）的结论；后一批新加的另一行也在
#   ② 先合的那支日期更新 → 后合的旧日期不覆盖它
#   ③ 没登记键的表（名单_直连缺陷上游）两边各加一行 → 两行都在、相同行只一份
#   ④ 两边表头不同 → 仍冲突（留给人）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid GIT_CONFIG_GLOBAL=/dev/null
R=$T/r; git init -q -b main $R; cd $R
git config merge.s2a-reglist.driver "python3 $H/tools/reglist_merge.py %O %A %B %P"
printf 'docs/名单_*/*.tsv merge=s2a-reglist\n' > .gitattributes
F=docs/名单_60帧逻辑速度/0100D71004694000.tsv; U=docs/名单_直连缺陷上游/0100D71004694000.tsv; mkdir -p $(dirname $F) $(dirname $U)
HD=$'程序号\t构建号\t款\t结论\tρ\tq\t依据\t日期\t放行'
row() { printf '0100D71004694000\t%s\tMinecraft\t%s\t1\t1\t%s\t%s\t-\n' "$1" "$2" "$3" "$4"; }
{ echo "$HD"; row aaaa 基线 c0 2026-11-04; } > $F; printf '程序号\t关键词\t上游\t下一步\n0100D71004694000\tk0\tu0\t-\n' > $U
git add -A; git commit -qm base
git checkout -q -b flk1; { echo "$HD"; row aaaa 无风险 flk1 2026-11-05; } > $F; printf '程序号\t关键词\t上游\t下一步\n0100D71004694000\tk0\tu0\t-\n0100D71004694000\tk1\tu1\t-\n' > $U; git commit -qam flk1
git checkout -q main; git checkout -q -b flk2; { echo "$HD"; row aaaa 有风险 flk2 2026-11-05; row bbbb 无风险 flk2b 2026-11-05; } > $F
printf '程序号\t关键词\t上游\t下一步\n0100D71004694000\tk0\tu0\t-\n0100D71004694000\tk2\tu2\t-\n' > $U; git commit -qam flk2
git checkout -q main; git merge -q --no-edit flk1 > /dev/null 2>&1; m1=$?; git merge -q --no-edit flk2 > /dev/null 2>&1; m2=$?
ck "① 两批同日登记同一款：依次合并都不冲突（rc ${m1} / ${m2}），最终 aaaa 是后一批 flk2 的结论、flk2 新加的 bbbb 也在" '[ $m1 = 0 ] && [ $m2 = 0 ] && grep -q "aaaa	Minecraft	有风险	.*flk2" $F && [ "$(grep -c "^0100D71004694000	aaaa" $F)" = 1 ] && grep -q "bbbb" $F'
ck "③ 没登记键的表：k1、k2 都在，k0 只一份" 'grep -q "	k1	" $U && grep -q "	k2	" $U && [ "$(grep -c "	k0	" $U)" = 1 ]'
git checkout -q -b new1 main; { echo "$HD"; row aaaa 新结论 new1 2026-11-07; row bbbb 无风险 flk2b 2026-11-05; } > $F; git commit -qam new1
git checkout -q -b old2 HEAD~1; { echo "$HD"; row aaaa 旧结论 old2 2026-11-06; row bbbb 无风险 flk2b 2026-11-05; } > $F; git commit -qam old2
git checkout -q main; git merge -q --no-edit new1 > /dev/null 2>&1; git merge -q --no-edit old2 > /dev/null 2>&1; m3=$?
ck "② 先合的日期更新（11-07）→ 后合的旧日期（11-06）不覆盖（rc ${m3}）" '[ $m3 = 0 ] && grep -q "新结论" $F && ! grep -q "旧结论" $F'
git checkout -q -b hd1 main; sed -i.b '1s/放行/放行1/' $F && rm -f $F.b; git commit -qam hd1
git checkout -q -b hd2 main; sed -i.b '1s/放行/放行2/' $F && rm -f $F.b; git commit -qam hd2
git checkout -q main; git merge -q --no-edit hd1 > /dev/null 2>&1; git merge -q --no-edit hd2 > /dev/null 2>&1; m4=$?; git merge --abort 2> /dev/null
ck "④ 两边表头不同 → 仍冲突（rc ${m4}）" '[ $m4 != 0 ]'
[ $bad = 0 ] && echo "reglist_merge 单测全过"; exit $bad
