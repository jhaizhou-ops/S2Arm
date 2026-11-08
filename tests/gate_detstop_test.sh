#!/bin/bash
# 门禁只看：tools/gate.sh tools/remote.sh tools/idle_timeout.sh tools/safe_killpg.sh
# 确定性步骤早停单测（临时仓库，本机 + S2A_REMOTE=local 模拟 mini，约 20 秒）：bash tests/gate_detstop_test.sh
# 期望（按 tools/gate.sh 早停规则手写）：
#   ① 本机：语法红（一个 .sh 语法错）+ 钩子 h 要睡 HL=600 秒 → 门禁在钩子睡完前结束（< HL）、红、退出 1；
#      钩子睡多久只是「没早停就要等它」的语义参数，取远大于任何负载下门禁耗时的值（11-01 mini 无缓存全套 ④ 推送 27 秒、共 49 秒，超原 40 秒线误红；10-29 ① 16 秒超原 15 秒线）；钩子记「⏹ … 没跑完（确定性步骤「语法」已红，早停）」；
#      红步行只有「语法」；末行前有「早停：」；「跑了 1 步 / 应跑 2 步」（没跑的不算跑了）
#   ② GATE_DET_STOP=0 → 不早停：钩子跑完（睡 3 秒版）、绿，红步只有语法、没有「早停：」
#   ③ 非确定性步骤红（单测 x_test 红）→ 不早停，钩子照跑完
#   ④ 模拟 mini（GATE_HOST=mini）：远端那份里语法红 → 远端早停，本机看到钩子「⏹」、结论带「早停：…（mini 那份）」，不当 mini 不可用、不退回本机补跑
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(cd "$(mktemp -d)" && pwd -P); bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
trap 'rm -rf "$T"' EXIT
unset GATE_TIER GATE_CHANGED GATE_PLAN GATE_OUT GATE_HOST GATE_REV GATE_REMOTE_NAME GATE_SKIP GATE_ONLY GATE_HOOK_S GATE_RERUN
export S2A_REMOTE_FREE_GB=999 S2A_REMOTE=local S2A_REMOTE_ROOT=$T/rr S2A_REMOTE_LOGS=$T/logs HOME=$T/home S2A_GATE_CPU_IDLE_MIN=0
mkdir -p $T/home $T/r/tools $T/r/tests $T/r/h; cd $T/r || exit 1; mkdir -p $T/home/.s2arm/run/s2arm/bin && echo '# 测试用局槽仲裁副本' > $T/home/.s2arm/run/s2arm/bin/mac_slot-now.sh   # remote.sh 本机缺副本不派（tools/mac_slot_frozen.sh）
git init -q; git config user.email t@t; git config user.name t; echo build/ > .gitignore
cp $H/tools/gate.sh $H/tools/remote.sh $H/tools/idle_timeout.sh $H/tools/safe_killpg.sh tools/
HL=600; printf 'sleep "${HS:-%s}"; echo "钩子跑完 → 过"\n' $HL > h/gate.sh
printf 'if then\n' > tools/bad.sh
git add -A; git commit -qm a
s=$SECONDS; GATE_TIER=full HS=$HL bash tools/gate.sh > $T/o1 2>&1; r1=$?; d1=$((SECONDS - s))
ck "① 本机早停：${d1} 秒结束（钩子要睡 ${HL} 秒）、退出 1（${r1}）、钩子记没跑完、红步只有语法、有「早停：」、跑了 1 步 / 应跑 2 步" '[ $d1 -lt $HL ] && [ $r1 = 1 ] && grep -q "^⏹ 钩子 h/gate.sh：没跑完（确定性步骤「语法」已红，早停）" $T/o1 && [ "$(grep "^红步" $T/o1)" = "红步	语法" ] && grep -q "^早停：确定性步骤「语法」红" $T/o1 && grep -q "跑了 1 步 / 应跑 2 步" $T/o1'
GATE_TIER=full HS=3 GATE_DET_STOP=0 bash tools/gate.sh > $T/o2 2>&1
ck "② GATE_DET_STOP=0：钩子跑完绿、没有早停" 'grep -q "^🟢 钩子 h/gate.sh" $T/o2 && ! grep -q "^早停" $T/o2 && [ "$(grep "^红步" $T/o2)" = "红步	语法" ]'
git rm -q tools/bad.sh; printf 'echo 红 → 不过; exit 1\n' > tests/x_test.sh; git add -A; git commit -qm b
GATE_TIER=full HS=3 bash tools/gate.sh > $T/o3 2>&1
ck "③ 非确定性步骤（单测 x_test）红：不早停、钩子跑完" 'grep -q "^🔴 单测 x_test" $T/o3 && grep -q "^🟢 钩子 h/gate.sh" $T/o3 && ! grep -q "^早停" $T/o3'
git rm -q tests/x_test.sh; printf 'if then\n' > tools/bad.sh; git add -A; git commit -qm c
s=$SECONDS; GATE_TIER=full HS=$HL GATE_HOST=mini bash tools/gate.sh > $T/o4 2>&1; r4=$?; d4=$((SECONDS - s))
ck "④ 模拟 mini：远端早停（${d4} 秒，钩子要睡 ${HL} 秒）、钩子［mini］记没跑完、结论带早停（mini 那份）、不退回本机补跑（${r4}）" '[ $d4 -lt $HL ] && [ $r4 = 1 ] && grep -q "^⏹ 钩子 h/gate.sh［mini］：没跑完" $T/o4 && grep -q "^早停：.*（mini 那份）" $T/o4 && ! grep -q "退回本机补跑" $T/o4'
# ⑤ 本机步不继承列车控制变量（11-05）：单测 envleak_test 看到 TRAIN_RN / S2A_TRAIN_ONLY 就红；带着这两个变量跑门禁 → 它绿
mkdir -p tests; git rm -q tools/bad.sh; printf '[ -z "${TRAIN_RN:-}${S2A_TRAIN_ONLY:-}" ] || { echo "看到列车变量 TRAIN_RN=${TRAIN_RN:-} S2A_TRAIN_ONLY=${S2A_TRAIN_ONLY:-}"; exit 1; }; echo "环境干净 → 过"\n' > tests/envleak_test.sh; git add -A; git commit -qm d
TRAIN_RN=train-fast S2A_TRAIN_ONLY=x GATE_TIER=full HS=1 bash tools/gate.sh > $T/o5 2>&1
ck "⑤ 本机步不继承 TRAIN_* / S2A_TRAIN_*：envleak_test 绿" 'grep -q "^🟢 单测 envleak_test" $T/o5'
# ⑥ 步自己的进程被 TERM（11-05 不稳定清单第 1 项）：单测 sig_test 往上三层（bash -c → timeout → 门禁的步子 shell）发 TERM →
#   （往上找第一个命令行是「bash tools/gate.sh」的祖先 = 这一步的子 shell，门禁主进程在它上面）这一步留退出码 143、日志写「被信号 TERM 停」，不再是「没跑完（无退出码）」
mkdir -p tests; git rm -q -r --ignore-unmatch tools/bad.sh > /dev/null; printf 'p=$PPID; while [ "$p" -gt 1 ] && [ "$(ps -o command= -p $p)" != "bash tools/gate.sh" ]; do p=$(ps -o ppid= -p $p | tr -d " "); done; kill -TERM $p; sleep 5; echo 不该到这\n' > tests/sig_test.sh; git add -A; git commit -qm e
GATE_TIER=full HS=1 bash tools/gate.sh > $T/o6 2>&1
ck "⑥ 步子 shell 被 TERM：sig_test 记 rc=143 + 被信号 TERM 停，不是无退出码" 'grep -a "单测 sig_test" $T/o6 | grep -q "rc=143" && grep -aq "被信号 TERM 停" $T/o6 && ! grep -aq "sig_test：没跑完" $T/o6'
[ $bad = 0 ] && echo "gate_detstop 单测全过" || { echo "gate_detstop 单测有不通"; for f in $T/o1 $T/o4; do echo "== $f"; tail -8 $f; done; exit 1; }
