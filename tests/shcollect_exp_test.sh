#!/bin/bash
# 收集器候选单测（graphics/tools/shbake/shcollect.sh，S2A_SHCOLLECT_LIST=1 只列候选）：bash tests/shcollect_exp_test.sh
#   造调度目录：正式局（BUNDLE=io.s2arm.g）、实验局（BUNDLE=io.s2arm-exp.g）、别款正式局，各带 shcache_rt/shared.toc → 期望只列正式局那一份；显式给实验局目录 → 照收
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0; trap 'rm -rf "$T"' EXIT
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
mk() { mkdir -p $T/sched/jobs/$1/out_1/shcache_rt; : > $T/sched/jobs/$1/out_1/shcache_rt/shared.toc; printf 'GAME=%s\nBUNDLE=%s\n' $2 $3 > $T/sched/jobs/$1/job.env; }
mk formal g io.s2arm.g; mk exp g io.s2arm-exp.g; mk other h io.s2arm.h
mkdir -p $T/base/shaders/shcache/0100aaaa00000000; printf '#!/bin/bash\necho "没有 shared.toc"\n' > $T/sb; chmod +x $T/sb
export S2A_SCHED_DIR=$T/sched S2A_SHBAKE=$T/sb S2A_SHCOLLECT_BASE=$T/base S2A_SHCOLLECT=$T/col S2A_SHCOLLECT_LIST=1
o=$(bash $H/graphics/tools/shbake/shcollect.sh g); ck "只收正式局（实验局 io.s2arm-exp.* 不收、别款不收）：$(echo $o | sed "s#$T/##g")" '[ "$o" = "$T/sched/jobs/formal/out_1/shcache_rt" ]'
o=$(bash $H/graphics/tools/shbake/shcollect.sh g $T/sched/jobs/exp/out_1); ck "显式给实验局目录 → 照收" '[ "$o" = "$T/sched/jobs/exp/out_1/shcache_rt" ]'
[ $bad = 0 ] && echo "收集器候选单测全过" || { echo "收集器候选单测有不通"; exit 1; }
