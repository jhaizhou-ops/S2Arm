#!/bin/bash
# ship.sh 遇门禁退出 75（环境未就绪）单测（约 1 秒，审计 #799 F-gate-75-reject）：bash tests/ship_env75_test.sh
# 临时仓库放假门禁：FAKE_RC=75 → ship 打「环境未就绪」、退出 75、不提交（HEAD 不变）、不入队（假 train.sh 没被调）；FAKE_RC=1 → 照旧「门禁红」退出 1（正控）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
git init -q -b main $T/r; cd $T/r; git config user.email t@t; git config user.name t; mkdir tools
cp $H/tools/ship.sh tools/; printf '#!/bin/bash\necho "门禁 假结论"; exit ${FAKE_RC:-0}\n' > tools/gate.sh; printf '#!/bin/bash\necho enq >> %s/enq.log\n' $T > tools/train.sh
git add -A; git commit -qm base; H0=$(git rev-parse HEAD); echo x > tools/x.sh; git add tools/x.sh; echo 说明 > $T/msg
o=$(FAKE_RC=75 MERGE_OWNER=甲 bash tools/ship.sh $T/msg 说明 2>&1); r=$?
ck "门禁 75：打环境未就绪、退出 75（${r}）、没提交、没入队" '[ $r = 75 ] && grep -q "环境未就绪" <<< "$o" && [ "$(git rev-parse HEAD)" = "$H0" ] && [ ! -f $T/enq.log ]'
o=$(FAKE_RC=1 MERGE_OWNER=甲 bash tools/ship.sh $T/msg 说明 2>&1); r=$?
ck "正控：门禁 1 照旧报门禁红、退出 1（${r}）" '[ $r = 1 ] && grep -q "门禁红" <<< "$o" && [ "$(git rev-parse HEAD)" = "$H0" ]'
[ $bad = 0 ] && echo "ship_env75 单测全过" || echo "ship_env75 单测有不通"; exit $bad
