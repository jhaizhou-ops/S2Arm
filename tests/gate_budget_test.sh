#!/bin/bash
# 门禁钩子自报预算单测（临时仓库，约 10 秒）：bash tests/gate_budget_test.sh
# 期望（按规则手写）：带「# 门禁预算：--budget」的钩子 A 自报 1500 → GATE_BUDGET_Q=1 打 1500、什么都不跑；不带标记的钩子 B 查预算时根本不被调用（它不认参数、会整份跑）；
#   正常跑：GATE_HOOK_S=1、两个钩子都睡 2 秒 → A 按自报 1500 秒上限跑完（绿），B 撞缺省 1 秒上限（红）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0; trap 'rm -rf "$T"' EXIT
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
unset GATE_TIER GATE_CHANGED GATE_PLAN GATE_OUT GATE_HOST GATE_REV GATE_REMOTE_NAME GATE_SKIP GATE_ONLY GATE_HOOK_S GATE_BUDGET_Q   # 本单测自己造门禁：不继承外层门禁的控制变量
mkdir -p $T/r/tools $T/r/ha $T/r/hb; cd $T/r || exit 1; cp $H/tools/gate.sh $H/tools/gate_plan.sh tools/
printf '#!/bin/bash\n# 门禁预算：--budget\n[ "${1:-}" = --budget ] && { echo 1500; exit 0; }\ntouch %s/ranA; sleep 2; echo "A 期望 → 真结果 绿"\n' "$T" > ha/gate.sh
printf '#!/bin/bash\ntouch %s/ranB; sleep 2; echo "B 期望 → 真结果 绿"\n' "$T" > hb/gate.sh
git init -q; git config user.email t@t; git config user.name t; git add -A; git commit -qm 1
b=$(GATE_BUDGET_Q=1 bash tools/gate.sh 2> /dev/null | tail -1)
ck "预算查询：打 A 自报的 1500（实为 ${b}）、A / B 都没真跑、B 连 --budget 都没被调" '[ "$b" = 1500 ] && [ ! -e $T/ranA ] && [ ! -e $T/ranB ]'
o=$(GATE_HOOK_S=1 bash tools/gate.sh 2>&1)
ck "正常跑：A 按自报上限跑完绿、B 撞缺省 1 秒上限 → 超时未判（11-04 起不算红）" 'grep -q "🟢 钩子 ha/gate.sh" <<< "$o" && grep -q "🟡 钩子 hb/gate.sh" <<< "$o"'
ck "B 真撞上限：写「超时未判：跑满 1 秒上限被杀」" 'grep "🟡 钩子 hb/gate.sh" <<< "$o" | grep -q "超时未判：跑满 1 秒上限被杀"'
# 单测自报上限（10-30 列车线：train_test 在 mini 上超缺省 600 秒）：文件头「# 门禁预算：<秒>」→ 本步上限用它、计入预算查询；不带的单测照缺省上限
mkdir -p tests; printf '#!/bin/bash\n# 门禁预算：1700\nsleep 2; echo "U 期望 → 真结果 绿"\n' > tests/u_test.sh; printf '#!/bin/bash\nsleep 2; echo "V 期望 → 真结果 绿"\n' > tests/v_test.sh
git add -A; git commit -qm u; b=$(GATE_BUDGET_Q=1 bash tools/gate.sh 2> /dev/null | tail -1); o=$(GATE_HOOK_S=1 bash tools/gate.sh 2>&1)
ck "单测自报上限：预算查询打 1700（实为 ${b}）、带标记的 u_test 按 1700 跑完绿、不带的 v_test 撞缺省 1 秒 → 超时未判" '[ "$b" = 1700 ] && grep -q "🟢 单测 u_test" <<< "$o" && grep -q "🟡 单测 v_test.*跑满 1 秒上限" <<< "$o"'
git rm -q tests/u_test.sh tests/v_test.sh; git commit -qm u2
# 钩子自己退出 124（它内部 timeout 到点，10-21 services/gate.sh 162 秒被写成「超 600 秒」，总指挥当成预算算错）：上限 30 秒、0 秒就退 124 → 不写「超 30 秒」，写明是这一步自己退出
mkdir -p hc; printf '#!/bin/bash\necho "C 内部超时"; exit 124\n' > hc/gate.sh
git add -A; git commit -qm 2; o=$(GATE_HOOK_S=30 bash tools/gate.sh 2>&1)
ck "C 自己退 124：不写「超 30 秒」、写「没到 30 秒上限：是这一步自己退出 124」" 'grep "🔴 钩子 hc/gate.sh" <<< "$o" | grep -q "没到 30 秒上限：是这一步自己退出 124" && ! grep "钩子 hc/gate.sh" <<< "$o" | grep -q "超 30 秒"'
# 显卡优先步骤（graphics/gate.sh 经 mac_slot prio，10-31 总指挥）：排队（独占锁 + 等 Mac 局让出）不占钩子上限，钩子上限在拿齐后才计时；
#   本步外层上限 = 钩子上限 + 排队上限 S2A_GATE_GPU_QUEUE_S + 30。别的门禁显卡步骤先占锁 3 秒、钩子上限 2 秒、钩子睡 1 秒 → 绿（排队算进钩子上限会红）；
#   预算查询报 2 + 60 + 30
mkdir -p $T/g2/tools $T/g2/gfx; cd $T/g2 || exit 1; cp $H/tools/gate.sh $H/tools/gate_plan.sh $H/tools/mac_slot.sh $H/tools/mac_slot_frozen.sh $H/tools/s2a_machine.sh tools/; export S2A_MAC_SLOT_BIN=$T/g2/tools/mac_slot.sh; printf '#!/bin/bash\nsleep 1; echo "G 期望 → 真结果 绿"\n' > graphics/gate.sh
git init -q; git config user.email t@t; git config user.name t; git add -A; git commit -qm 1
export S2A_MAC_SLOT_DIR=$T/g2slot; mkdir -p $T/g2slot.gate; sleep 3 & HP=$!; printf '%s\n别的门禁\n' $HP > $T/g2slot.gate/pid
o=$(GATE_HOOK_S=2 S2A_GATE_GPU_QUEUE_S=60 bash tools/gate.sh 2>&1); bq=$(GATE_BUDGET_Q=1 GATE_HOOK_S=2 S2A_GATE_GPU_QUEUE_S=60 bash tools/gate.sh 2> /dev/null | tail -1)
ck "显卡优先步骤排队 3 秒不占钩子上限 2 秒：睡 1 秒的钩子绿；预算查询报 92（实为 ${bq}）" 'grep -q "🟢 钩子 graphics/gate.sh" <<< "$o" && [ "$bq" = 92 ]'
# 只改 .md / docs/ → doc 档（不管目录、不管给的什么档；10-22 PR #12 只改 android/README.md，入队前门禁按 full 跑）：
#   改动集取 origin/main...HEAD；显式 GATE_TIER=full 也按 doc；再改一个 .c → 照 full 跑钩子；GATE_CHANGED 给了就按它
cd $T/r || exit 1; git update-ref refs/remotes/origin/main HEAD; mkdir -p android docs; echo x > android/README.md; echo y > docs/note.txt; git add -A; git commit -qm doc
od=$(GATE_TIER=full GATE_HOOK_S=30 bash tools/gate.sh 2>&1 | tail -1)
echo 'int x;' > ha/x.c; git add -A; git commit -qm code; of=$(GATE_HOOK_S=30 bash tools/gate.sh 2>&1 | tail -1)
oc=$(GATE_CHANGED="android/README.md docs/a.txt" GATE_HOOK_S=30 bash tools/gate.sh 2>&1 | tail -1)
ck "只改 android/README.md + docs/note.txt、给了 GATE_TIER=full → doc 档，跑了 0 步 / 应跑 0 步（${od}）；再改 ha/x.c → 照跑钩子（${of}）；GATE_CHANGED 只列文档 → doc（${oc}）" '[[ "$od" == *"doc 档，跑了 0 步 / 应跑 0 步"* ]] && [[ "$of" != *"doc 档"* ]] && [[ "$of" == *"跑了"* ]] && [[ "$oc" == *"doc 档，跑了 0 步 / 应跑 0 步"* ]]'
cd $H
cd $T || true
[ $bad = 0 ] && echo "gate_budget 单测全过" || { echo "gate_budget 单测有不通"; echo "$o" | tail -5; exit 1; }
