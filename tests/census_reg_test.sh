#!/bin/bash
# 普查收批登记单测（tools/census/reg.sh，11-02）：bash tests/census_reg_test.sh，约 10 秒
# 门禁覆盖：tools/census/reg.sh tools/census/census.sh tools/fps_ab_ledger.py tools/census/hand_test_list.py
# 登记树用本仓库当前提交临时 worktree add（CENSUS_REG_REPO / CENSUS_REG_BASE 指过去），入队换成 echo（CENSUS_REG_ENQUEUE），不碰真列车；
# 建出来的 census-reg/regtest_* 分支与临时树退出时删掉。期望都手写：
#   ① 批次里一款同局 A/B 绿 → 退出 0、建一支 census-reg/regtest_<pid>_g-* 分支、提交只改 docs/名单_60帧逻辑速度/0100AAAA00000000.tsv、那一行结论绿、放行空、入队被调；登记树回到基点且干净
#   ② 批次里只有判不出 → 「无新登记」、不建分支、不入队
#   ③ 登记树有未提交改动 → 退出 1、一行红、不建分支
#   ④ 读锁登记表（CENSUS_HDD_OFFICIAL，指临时文件）里有本批名 → 收批删掉本批那一行、别批留着；就算后面登记一步红退出（③那种）也照删
#   ⑤ 待手测总清单（CENSUS_DIR 指临时普查目录，里面一批总表一款通过没进局）→ 每次收批刷新成 1 款、不留 .new；就算后面登记一步红退出（③那种）也照刷
#   ⑥ 普查目录缺 手测结果.tsv → 一行「【红】…待手测总清单刷新失败」、登记照做（②的退出码 0、「无新登记」不变）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0
RT=$T/reg; TAG=regtest_$$
cleanup() { git -C "$H" worktree remove --force "$RT" > /dev/null 2>&1; git -C "$H" for-each-ref --format='%(refname:short)' "refs/heads/census-reg/${TAG}_*" | xargs -n1 git -C "$H" branch -D > /dev/null 2>&1; rm -rf "$T"; }
trap cleanup EXIT
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
BASE=$(git -C "$H" rev-parse HEAD)
H2='键	名称	版本	构建号	结论	ρ	q	量法	关段像素每秒	开段像素每秒	关段帧率	开段帧率	说明	日期	局目录'
BID=$(printf 'a%.0s' $(seq 32))
mk() { mkdir -p "$T/$1"; printf '%s\n0100AAAA00000000\t款\t1.0\t%s\t%s\t1.02\t2.0\t推左摇杆走\t40\t41\t30\t60\t\t2026-11-02\tx\n' "$H2" "$BID" "$2" > "$T/$1/逻辑速度.tsv"; }
CD=$T/census; mkdir -p "$CD/c1101x"; printf '键\t手测\n' > "$CD/手测结果.tsv"; echo type=主批 > "$CD/c1101x/.census_batch"
printf '键\t名称\t结论\t进局\t日期\t源GB\n0100CCCC00000000\t款\t通过\t否\t2026-11-02\t1\n' > "$CD/c1101x/总表.tsv"
run() { CENSUS_DIR=${RCD:-$CD} CENSUS_HDD_GLOB=$T/nohdd CENSUS_HDD_OFFICIAL=$T/official CENSUS_REG_REPO=$RT CENSUS_REG_BASE=$BASE CENSUS_REG_ENQUEUE="echo 入队" bash "$H/tools/census/reg.sh" "$T/$1" > "$T/$1.out" 2>&1; echo $?; }
mk "${TAG}_g" 绿; r=$(run "${TAG}_g")
br=$(git -C "$H" for-each-ref --format='%(refname:short)' "refs/heads/census-reg/${TAG}_g-*" | head -1)
files=$([ -n "$br" ] && git -C "$H" -c core.quotepath=off show --name-only --format= "$br" | tr '\n' ' ')
row=$([ -n "$br" ] && git -C "$H" show "$br:docs/名单_60帧逻辑速度/0100AAAA00000000.tsv" 2> /dev/null | tail -1 | awk -F'\t' '{print $4 "|" $9 "|"}')
ck "① 绿一款：退出 ${r}、分支 ${br:-无}、改了「${files}」、行「${row}」（期望 结论绿 放行空）、入队被调、登记树回基点且干净" \
  '[ "$r" = 0 ] && [ -n "$br" ] && [ "$files" = "docs/名单_60帧逻辑速度/0100AAAA00000000.tsv " ] && [ "$row" = "绿||" ] && grep -q "^入队 census-reg/${TAG}_g-" "$T/${TAG}_g.out" && [ "$(git -C "$RT" rev-parse HEAD)" = "$BASE" ] && [ -z "$(git -C "$RT" status --porcelain)" ]'
mk "${TAG}_n" 判不出; r=$(run "${TAG}_n")
ck "② 只有判不出：退出 ${r}、「$(tail -1 "$T/${TAG}_n.out")」、不建分支、不入队" \
  '[ "$r" = 0 ] && grep -q "无新登记" "$T/${TAG}_n.out" && [ -z "$(git -C "$H" for-each-ref "refs/heads/census-reg/${TAG}_n-*")" ] && ! grep -q "^入队" "$T/${TAG}_n.out"'
printf '%s\n%s\n' 别批 "${TAG}_d" > "$T/official"
echo x >> "$RT/README.md"; mk "${TAG}_d" 绿; r=$(run "${TAG}_d")
ck "③ 登记树有未提交改动：退出 ${r}、「$(tail -1 "$T/${TAG}_d.out" | cut -c1-80)」、不建分支" \
  '[ "$r" = 1 ] && grep -q "【红】普查收批登记：登记树" "$T/${TAG}_d.out" && [ -z "$(git -C "$H" for-each-ref "refs/heads/census-reg/${TAG}_d-*")" ]'
ck "④ 收批删读锁登记：登记表剩「$(tr '\n' ' ' < "$T/official")」（期望只剩 别批）" '[ "$(cat "$T/official")" = 别批 ]'
rm -f "$CD/待手测总清单.tsv"; echo x >> "$RT/README.md"; r=$(run "${TAG}_d"); git -C "$RT" checkout -q -- README.md
ck "⑤ 收批刷新待手测总清单（登记红退出 ${r} 也照刷）：「$(grep 待手测总清单 "$T/${TAG}_d.out" | cut -c1-60)」、清单 $(tail -n +2 "$CD/待手测总清单.tsv" 2> /dev/null | cut -f1)" \
  '[ "$r" = 1 ] && grep -q "待手测总清单刷新 → 待手测 1 款" "$T/${TAG}_d.out" && [ "$(tail -n +2 "$CD/待手测总清单.tsv" | cut -f1)" = 0100CCCC00000000 ] && [ ! -e "$CD/待手测总清单.tsv.new" ]'
mkdir -p "$T/nocd"; r=$(RCD=$T/nocd run "${TAG}_n")
ck "⑥ 缺手测结果：退出 ${r}、「$(grep 待手测总清单 "$T/${TAG}_n.out" | cut -c1-60)」、「$(tail -1 "$T/${TAG}_n.out")」" \
  '[ "$r" = 0 ] && [ "$(grep -c "【红】普查收批登记：待手测总清单刷新失败" "$T/${TAG}_n.out")" = 1 ] && grep -q "无新登记" "$T/${TAG}_n.out"'
[ $bad = 0 ] && echo "✅ 普查收批登记全通" || { echo "🔴 普查收批登记有不通项"; exit 1; }
