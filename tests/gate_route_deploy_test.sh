#!/bin/bash
# 门禁只看：tools/gate_route.py
# 单测覆盖面不把「部署出去的运行时副本」认成仓库文件（合成仓，约 1 秒）：bash tests/gate_route_deploy_test.sh
# 期望（按 gate_route.py 规则手写）：tests/x_test.sh 调 tools/caller.sh；caller.sh 里
#   ① bash "${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/bin/train-now/runner.sh"（两层以上目录、目录名仓库里没有）→ 不是依赖：改 tools/runner.sh 不跑 x_test
#   ② bash "$TOOLS/helper.sh"（变量 + 文件名）→ 照旧按文件名认：改 tools/helper.sh 跑 x_test
#   ③ bash "$H/tools/real.sh"（后缀是仓库路径）→ 认：改 tools/real.sh 跑 x_test
#   10-29 列车线：tools/ledger_post.sh 调部署的列车副本，按文件名挂到 tools/train.sh，改列车一批路由出 79 个单测
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
mkdir -p $T/r/tools $T/r/tests; cd $T/r || exit 1; git init -q
cp $H/tools/gate_route.py tools/; printf '# 合成仓\n' > tools/gate_route.tsv
for f in runner helper real; do echo "echo $f" > tools/$f.sh; done
printf 'bash "${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/bin/train-now/runner.sh" enqueue x\nbash "$TOOLS/helper.sh"\nbash "$H/tools/real.sh"\n' > tools/caller.sh
printf 'bash tools/caller.sh\n' > tests/x_test.sh
git add -A; git -c user.name=t -c user.email=t@t commit -qm a
r() { python3 tools/gate_route.py tests "$1"; }
ck "① 改 tools/runner.sh（只被部署副本路径点名）→ 不跑 x_test" '! r tools/runner.sh | grep -q x_test'
ck "② 改 tools/helper.sh（\$TOOLS/helper.sh）→ 跑 x_test" 'r tools/helper.sh | grep -q x_test'
ck "③ 改 tools/real.sh（\$H/tools/real.sh）→ 跑 x_test" 'r tools/real.sh | grep -q x_test'
[ $bad = 0 ] && echo "gate_route_deploy 单测全过" || { echo "gate_route_deploy 单测有不通"; exit 1; }
