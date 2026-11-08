#!/bin/bash
# 门禁负载排队单测（10-24 jhz 重新分工：本机 15 分钟负载超过 36 时新门禁先排队，双轨 / 列车豁免）：bash tests/gate_loadq_test.sh，约 10 秒
# 期望（按规则手写）：CPU 实际空闲 3% < 15% → 打「先排队」、等到上限（2 秒）照跑并打黄字；GATE_DUAL=1 / GATE_NO_LOADQ=1 → 不排；空闲 60% → 不排；读不到空闲 → 不排
# 门禁只跑一个不存在的步（GATE_RERUN），不真跑任何步骤
set -u; H=$(cd "$(dirname "$0")/.." && pwd); bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
g() { (cd "$H" && env "$@" S2A_GATE_LOAD_WAIT_S=2 S2A_GATE_LOAD_POLL_S=0.5 GATE_HOST=local GATE_TIER=tool GATE_CHANGED="tools/gc.sh" GATE_RERUN="没有这一步" timeout 600 bash tools/gate.sh 2>&1); }   # 600 秒只防挂死（10-25：每次先整算一遍路由，空闲 12 秒、CPU 8 秒，本机满载时撞原 60 秒上限、输出截断判红）
o1=$(g S2A_GATE_IDLE_TEST=3); o2=$(g S2A_GATE_IDLE_TEST=3 GATE_DUAL=1); o3=$(g S2A_GATE_IDLE_TEST=3 GATE_NO_LOADQ=1); o4=$(g S2A_GATE_IDLE_TEST=60)
ck "CPU 空闲 3%：先排队、到上限照跑（打黄字）" 'grep -q "门禁先排队" <<< "$o1" && grep -q "到上限照跑" <<< "$o1"'
ck "双轨门禁（GATE_DUAL=1）、列车门禁（GATE_NO_LOADQ=1）：CPU 空闲 3% 也不排" '! grep -q "CPU 实际空闲" <<< "$o2" && ! grep -q "CPU 实际空闲" <<< "$o3"'
ck "CPU 空闲 60%：不排" '! grep -q "CPU 实际空闲" <<< "$o4"'
# 读不到负载（Linux 没有 vm.loadavg；审计 #829 F-gate-loadq-comment：跳出写在了行尾注释里被吃掉，空等满上限）→ 不排、不打负载行
FB=$(mktemp -d); printf '#!/bin/sh\nexit 1\n' > "$FB/top"; chmod +x "$FB/top"; o5=$(g PATH="$FB:$PATH"); rm -rf "$FB"
ck "读不到 CPU 空闲（没有 top）：不排、不打排队行" '! grep -q "CPU 实际空闲" <<< "$o5"'
[ $bad = 0 ] && echo "gate_loadq 单测全过" || { echo "gate_loadq 单测有不通"; exit 1; }
