#!/bin/bash
# 普查收批登记（11-02 总指挥 / 运维线定）：bash tools/census/reg.sh <批次目录>
#   批次跑完（census.sh 末尾 census.py sum 之后）把本批读数写进仓库按款登记表，提交成一支分支、入列车。四类：
#   60 帧逻辑速度同局 A/B（tools/fps_ab_ledger.py merge ← <批次>/逻辑速度.tsv）、原生 60（census.py native60）、直连实测（direct_reg）、
#   宽屏两侧缺渲染（widen_cliff）。原先都靠各线批后手跑，迟早漏一批。
# 写在专用登记树（CENSUS_REG_REPO，缺省 ~/.s2arm/wt/census_reg；没有就从本仓库 worktree add）里，每次先 detach 到 CENSUS_REG_BASE（缺省 origin/main）：
#   普查工作树是钉在基点上的只读检出，remote.sh 要求它干净，不能往里写 docs/。
# 有新登记 → 建分支 census-reg/<批次>-<时刻>、提交、入列车（CENSUS_REG_ENQUEUE，缺省 MERGE_OWNER=普查收批 的列车 enqueue；单测换成 echo）；没有 → 一行「无新登记」。
# 退出码：0 = 写好了或没东西写；1 = 某一步失败（census.sh 只记一行红，不改批次退出码）
set -u
B=${1:?批次目录}; R=$(cd "$(dirname "$0")/../.." && pwd); PY=${PY:-$HOME/.s2arm/venv/bin/python3}; [ -x "$PY" ] || PY=python3
RT=${CENSUS_REG_REPO:-$HOME/.s2arm/wt/census_reg}; BASE=${CENSUS_REG_BASE:-origin/main}
TRAIN=${CENSUS_REG_TRAIN:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/bin/train-now/train.sh}
red() { echo "【红】普查收批登记：$*"; exit 1; }
[ -d "$B" ] || red "没有批次目录 $B"
# 收批先删机械盘读锁登记（11-03 运维线）：起批脚本把批名写进 locks/hdd_read.lock.official（登记表非空时只有登记批能拿读锁），
#   收批不删 → 死名单一直占着、别的读者全排着等。放在下面任何一步红退出之前；写 .tmp 再 mv（读锁每 0.3 秒在读这份文件）
OFF=${CENSUS_HDD_OFFICIAL:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/locks/hdd_read.lock.official}; bn0=$(basename "$(cd "$B" && pwd)")
if [ -f "$OFF" ] && tr -s ' \t' '\n\n' < "$OFF" | grep -qxF "$bn0"; then
  tr -s ' \t' '\n\n' < "$OFF" | grep -vxF "$bn0" | grep -v '^$' > "$OFF.tmp.$$"; mv -f "$OFF.tmp.$$" "$OFF" && echo "普查收批登记：读锁登记表删掉 $bn0"
fi
# 待手测总清单跟着刷新（11-04 总指挥：原先靠人手跑，第二轮普查后停在 31 款没人重跑）：运行区文件，不进 docs、不进登记分支；
#   放在下面任何一步红退出之前；失败只打一行红、不影响登记。CENSUS_HAND_LIST 换输出路径（单测指临时目录），=0 不刷
HL=${CENSUS_HAND_LIST:-${CENSUS_DIR:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/census}/待手测总清单.tsv}
if [ "$HL" != 0 ]; then
  if hl=$("$PY" "$R/tools/census/hand_test_list.py" "$HL" 2>&1); then echo "普查收批登记：待手测总清单刷新 → $(echo "$hl" | head -1)（${HL}）"
    echo "$hl" | grep '^【红】' | sed 's/^【红】/【红】普查收批登记：待手测总清单：/'   # 读不到类型被跳过的批（不算进清单）
  else echo "【红】普查收批登记：待手测总清单刷新失败（$(echo "$hl" | tail -1 | cut -c1-120)），登记照做"; fi
fi
if [ ! -e "$RT/.git" ]; then git -C "$R" worktree add -q --detach "$RT" "$BASE" || red "建登记树 $RT 失败"; fi
[ -z "$(git -C "$RT" status --porcelain)" ] || red "登记树 $RT 有未提交改动（上一批收批中途停了？先看清再处理），这批不写"
git -C "$RT" checkout -q --detach "$BASE" || red "登记树切到 $BASE 失败"
bn=$(basename "$(cd "$B" && pwd)")
if [ -s "$B/逻辑速度.tsv" ]; then "$PY" "$R/tools/fps_ab_ledger.py" merge "$RT" "$B/逻辑速度.tsv" || red "逻辑速度入账失败"; fi
for c in native60 direct_reg widen_cliff; do "$PY" "$R/tools/census/census.py" "$c" "$B" "$RT" > /dev/null || red "census.py $c 失败"; done
[ -n "$(git -C "$RT" status --porcelain -- docs)" ] || { echo "普查收批登记：$bn 无新登记"; exit 0; }
[ -z "$(git -C "$RT" status --porcelain -- . ':(exclude)docs')" ] || red "登记树里 docs/ 以外也被改了，不提交"
br=census-reg/$bn-$(date +%m%d%H%M%S)
git -C "$RT" checkout -q -b "$br" && git -C "$RT" add -A docs && git -C "$RT" commit -q -m "普查 $bn 收批登记（tools/census/reg.sh）：$(git -C "$RT" diff --cached --stat HEAD 2> /dev/null | tail -1)" \
  || red "提交失败"
n=$(git -C "$RT" show --stat --format= HEAD | tail -1)
git -C "$RT" checkout -q --detach "$BASE"   # 登记树回到基点，下一批照样从干净状态起
if [ -n "${CENSUS_REG_ENQUEUE:-}" ]; then $CENSUS_REG_ENQUEUE "$br" "普查 $bn 收批登记" || red "入队失败（分支 $br 已提交）"
else out=$(MERGE_OWNER=普查收批 bash "$TRAIN" enqueue "$br" "普查 $bn 收批登记" 2>&1) || red "入队失败（分支 $br 已提交）：$(echo "$out" | tail -1)"; echo "$out" | tail -1; fi
echo "普查收批登记：$bn → ${br}（${n}）已入列车"
