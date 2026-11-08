#!/bin/bash
# 在两种 sed 上用临时文件完成同一替换。
sed_edit() { sed -i.s2a-bak "$1" "$2" && rm -f "$2.s2a-bak"; }
# 门禁派 mini 单测（tools/gate.sh 的 GATE_HOST=mini、tools/ship.sh 的临时提交、tools/train.sh 的列车门禁）：S2A_REMOTE=local 本机模拟远端，约 60 秒，不碰 mini。
# 假仓库：语法 + 单测 x_test + 三个钩子；钩子文件头「# 门禁本机：」：a 整步本机（*）、b 子项 k1 k2 本机另跑、c 没登记（整步 mini）。钩子把「名 / 所在目录 / GATE_SKIP / GATE_ONLY」记进 trace。
# 期望（按规则手写，不跑被测脚本先算）：
#   ① 分派：c、语法、单测在远端工作树 rr/wt/repo 跑；a 在本机仓库跑；b 在远端跑且 GATE_SKIP="k1 k2"、本机另跑一份 GATE_ONLY="k1 k2"（同一步的键合成一份）；绿、退出 0
#   ①b 门禁自己的控制变量不漏进各步（各步里再跑门禁的单测——gate_mini / train——会被当成远端计划）
#   ② 合并：「跑了 5 步 / 应跑 5 步」（语法 1 + 单测 1 + 钩子 3；b 拆两边仍算 1 步），结论行写「mini 4 步，其中 1 步的子项本机另跑；本机 1 步」，每步标［mini］/［本机］
#   ③ 远端某步红（b 在 mini 的那份 exit 1）→ 总结论红、退出 1、仍是 5 / 5；本机另跑的子项红 → 也红
#   ④ mini 不可用（远端工具链不同 / 连不上）/ ④b 排队超时 / ④c 磁盘不足 → 原派 mini 的步退回本机补跑（10-29 总指挥：mini 一出问题整条列车停）：
#      c 在本机跑、b 在本机补跑带 GATE_SKIP="k1 k2"（GATE_ONLY 那份本来就在本机）、全绿退出 0、写「退回本机补跑」；④d 另一台能用也不换 Air（10-28 Air 退出门禁池）
#   ④g GATE_FALLBACK_LOCAL=0 → 旧行为：环境未就绪、c 不补跑、退出 75
#   ④e GATE_HOST=air → 拒绝、退出 2；④f 补跑时本机另跑的子项真红 → 退出 1、门禁红
#   ⑤ 本机有、提交里没有的钩子（未跟踪 d/gate.sh）→ 远端算不出这一步 → 红，不静默少跑；工作树跟踪文件与提交不同 → 整份本机跑
#   ⑥ ship.sh：暂存改动在临时提交上派 mini（远端跑到的是暂存的新内容）；红 → 不提交、HEAD 与暂存区原样；绿 → 提交的树 = 门禁跑的树、入队
#   ⑦ 列车 land：门禁派 mini、远端工作树名固定 train；⑦b 快档用 train-fast（TRAIN_RN），不和慢档抢同一把远端工作树锁
# 反证：S2A_GATE_SH=<旧版 gate.sh> 跑本单测应红（旧版不认 GATE_HOST：全在本机跑 → ① 红）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(cd "$(mktemp -d)" && pwd -P); bad=0; GS=${S2A_GATE_SH:-$H/tools/gate.sh}
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
trap '[ -n "${KEEP:-}" ] || rm -rf "$T"' EXIT
unset GATE_TIER GATE_CHANGED GATE_PLAN GATE_OUT GATE_HOST GATE_REV GATE_REMOTE_NAME GATE_SKIP GATE_ONLY GATE_HOOK_S   # 本单测自己造门禁：不继承外层门禁的控制变量（10-21 列车 tool 档的 GATE_TIER 漏进来，假门禁只跑 2 步）
export S2A_REMOTE_FREE_GB=999   # 假远端就是本机：真实剩余不该决定用例（10-28 Air 只剩 22 GB < 远端阈值 30，除查盘用例外全部 125）；查盘用例行内另给 5 / 35
export S2A_REMOTE=local S2A_REMOTE_ROOT=$T/rr S2A_REMOTE_LOGS=$T/logs HOME=$T/home S2A_TRAIN_NO_POST=1
mkdir -p $T/home $T/repo/tools $T/repo/tests; cd $T/repo || exit 1; mkdir -p $T/home/.s2arm/run/s2arm/bin && echo '# 测试用局槽仲裁副本' > $T/home/.s2arm/run/s2arm/bin/mac_slot-now.sh   # remote.sh 本机缺副本不派（tools/mac_slot_frozen.sh）
git init -q; git config user.email t@t; git config user.name t
cp "$GS" tools/gate.sh; cp $H/tools/gate_plan.sh $H/tools/remote.sh $H/tools/idle_timeout.sh $H/tools/safe_killpg.sh $H/tools/disk_low.sh $H/tools/train.sh $H/tools/ship.sh $H/tools/gate_decl.py tools/; echo build/ > .gitignore
printf '#!/bin/bash\necho "x 单测全过"\n' > tests/x_test.sh
hook() {   # hook <名>：钩子记 trace；$T/red_<名>_skip 在时带 GATE_SKIP 的那份红，$T/red_<名>_only 在时带 GATE_ONLY 的那份红
  mkdir -p "$1"; cat > "$1/gate.sh" <<EOF
#!/bin/bash
echo "$1 \$(pwd) skip=\${GATE_SKIP:-} only=\${GATE_ONLY:-} \$(cat $1/ver 2> /dev/null)" >> $T/trace
[ -n "\${GATE_PLAN:-}\${GATE_OUT:-}\${GATE_HOST:-}\${GATE_REV:-}\${GATE_TIER:-}" ] && echo "$1 \$(pwd)" >> $T/leak
[ -n "\${GATE_SKIP:-}" ] && [ -e $T/red_$1_skip ] && { echo "$1 → 红（skip 份）"; exit 1; }
[ -n "\${GATE_ONLY:-}" ] && [ -e $T/red_$1_only ] && { echo "$1 → 红（only 份）"; exit 1; }
[ -e $T/env75_$1 ] && [ "\$(pwd)" = "$T/repo" ] && { echo "$1 → 环境未就绪（本机缺镜像）"; exit 75; }
[ -e $T/env75r_$1 ] && [ "\$(pwd)" != "$T/repo" ] && { echo "$1 → 环境未就绪（远端缺 docker）"; exit 75; }   # 只远端那份自报 75（11-02 mini 缺 docker 的 Vulkan 单测）   # 本机那份自报 75（10-29 #793 安卓 APK 子项缺镜像 / 缓存卷按设计退 75）
[ -e $T/redl_$1 ] && [ "\$(pwd)" = "$T/repo" ] && { echo "$1 → 红（本机那份：cc 超时）"; exit 1; }   # 只本机那份红（11-07 mini 自报 75 退回本机后本机超时）
[ -e $T/slow_$1 ] && for i in \$(seq 1 600); do [ -e $T/slow_$1 ] || break; sleep 0.1; done   # 慢步：跑到测试撤掉 slow_ 文件为止（上限 60 秒），不按固定秒数
echo "$1 期望 过 → 过"
EOF
}
hook a; hook b; hook c
# 本机步 / 子项声明在钩子自己的文件头（10-30 列车线：原 tools/gate_local.tsv 中央表拆回各文件；tools/gate_decl.py local 收）
sed -i '' '1a\
# 门禁本机：* 整步本机
' a/gate.sh; sed -i '' '1a\
# 门禁本机：k1 子项本机\
# 门禁本机：k2 子项本机（同一步两个键合成本机一份）
' b/gate.sh
git add -A; git commit -qm 1
RW=$T/rr/wt/repo; L=$T/repo
g() { : > $T/trace; GATE_TIER=full GATE_HOST=mini bash tools/gate.sh > $T/$1 2>&1; echo $?; }   # 显式给 GATE_TIER：①b 查它不漏给各步
has() { grep -qxF "$1" $T/trace; }

r=$(g o1)
ck "① 分派：c 在远端、a 在本机、b 远端带 GATE_SKIP=k1 k2 + 本机另跑一份 GATE_ONLY=k1 k2（rc=${r}）" '[ $r = 0 ] && has "c $RW skip= only= " && has "a $L skip= only= " && has "b $RW skip=k1 k2 only= " && has "b $L skip= only=k1 k2 " && [ $(grep -c . $T/trace) = 4 ]'
ck "①b 门禁的控制变量（GATE_PLAN / GATE_OUT / GATE_HOST / GATE_REV / GATE_TIER）不漏给各步（漏了：$(cat $T/leak 2> /dev/null | tr '\n' ' ')）" '[ ! -s $T/leak ]'
ck "② 合并：跑了 5 步 / 应跑 5 步、mini 4 步其中 1 步拆、本机 1 步；每步标位置" 'tail -1 $T/o1 | grep -qF "门禁 绿：full 档，跑了 5 步 / 应跑 5 步（mini 4 步，其中 1 步的子项本机另跑；本机 1 步）" && grep -q "^🟢 语法［mini］" $T/o1 && grep -q "^🟢 钩子 a/gate.sh［本机］" $T/o1 && grep -q "^🟢 钩子 b/gate.sh［mini，不含 k1 k2］" $T/o1 && grep -q "^    ↳ 🟢 本机另跑 k1 k2" $T/o1 && grep -q "^🟢 钩子 c/gate.sh［mini］" $T/o1'

touch $T/red_b_skip; r=$(g o2); rm -f $T/red_b_skip
ck "③ 远端 b 的那份红 → 总结论红、退出 1、仍 5 / 5（rc=${r}）" '[ $r = 1 ] && tail -1 $T/o2 | grep -qF "门禁 红：full 档，跑了 5 步 / 应跑 5 步" && grep -q "^🔴 钩子 b/gate.sh［mini，不含 k1 k2］" $T/o2'
touch $T/red_b_only; r=$(g o3); rm -f $T/red_b_only
ck "③ 本机另跑的子项红 → 总结论红（rc=${r}）" '[ $r = 1 ] && tail -1 $T/o3 | grep -qF "门禁 红：full 档，跑了 5 步 / 应跑 5 步" && grep -q "^    ↳ 🔴 本机另跑 k1 k2" $T/o3'
# ⑩ 本机步自报环境未就绪（退出 75，10-29 #793 安卓 APK 子项缺镜像 / 缓存卷）：同远端没就绪，记「没跑」、不进红步清单，没有别的真红 → 整体 75 留队，不退回分支
#   ⑩ 整步本机的 a 退 75 → 75；⑩b a 退 75 + 远端 b 真红 → 真红优先 1；⑩c b 的本机子项退 75 → 75
touch $T/env75_a; r=$(g o10); rm -f $T/env75_a
ck "⑩ 本机整步 a 自报 75 → 门禁环境未就绪、退出 75、红步清单不含 a（rc=${r}）" '[ $r = 75 ] && tail -1 $T/o10 | grep -qF "门禁 环境未就绪" && grep -q "^环境未就绪：本机步自报.*钩子 a/gate.sh" $T/o10 && ! grep -q "^红步.*钩子 a/gate.sh" $T/o10'
touch $T/env75_a $T/red_b_skip; r=$(g o10b); rm -f $T/env75_a $T/red_b_skip
ck "⑩b 本机 a 自报 75 + 远端 b 真红 → 真红优先、退出 1（rc=${r}）" '[ $r = 1 ] && tail -1 $T/o10b | grep -qF "门禁 红"'
touch $T/env75_b; r=$(g o10c); rm -f $T/env75_b
ck "⑩c b 在本机另跑的子项自报 75 → 退出 75（rc=${r}）" '[ $r = 75 ] && tail -1 $T/o10c | grep -qF "门禁 环境未就绪"'

# ⑪ 远端 c 自报 75（mini 缺 docker）、远端其余步绿 → 只把 c 退回本机补跑，b 不重跑（11-02：一步 75 曾让 mini 已绿的 11 步全部回本机）；期望手算：
#   退出 0、trace 有「c 本机」、没有「b 本机 skip=k1 k2」（b 的远端结果照用）、输出写「只这几步」
touch $T/env75r_c; r=$(g o11); rm -f $T/env75r_c
ck "⑪ 远端只 c 自报 75 → 只 c 退回本机补跑、b 不重跑、绿（rc=${r}）" '[ $r = 0 ] && has "c $L skip= only= " && ! has "b $L skip=k1 k2 only= " && grep -q "只这几步" $T/o11 && tail -1 $T/o11 | grep -qF "门禁 绿"'
# ⑪c 远端 c 自报 75、退回本机补跑也红（11-07：mini 安卓钩子 75，本机负载 31 时 cc 超时被判代码红，守望在 236 个候选里二分追噪声）→
#   按环境未就绪计：退出 75、末行「门禁 环境未就绪」、输出写「按环境未就绪计」、红步清单不含 c。期望手算：远端只 c 没跑出结论（75）、本机那份 exit 1 → 不是代码红
touch $T/env75r_c $T/redl_c; r=$(g o11c); rm -f $T/env75r_c $T/redl_c
ck "⑪c 远端 c 自报 75、本机补跑也红 → 环境未就绪 75，不算代码红（rc=${r}）" '[ $r = 75 ] && grep -q "按环境未就绪计" $T/o11c && tail -1 $T/o11c | grep -qF "门禁 环境未就绪" && ! grep -q "^红步.*c" $T/o11c'
# ⑪b 同 ⑪，但排队时 mini 超载过一次、之后降下来跑完（11-04 #1503：远端日志里有过「超载等降」，那 1 步 75 就没退回本机，第一层 34/35）
#   假 sysctl：第 1 次报负载 99（> 核数 × 1.5），之后报 0.1；远端 30 秒后复查即接单。期望手算：同 ⑪ 退出 0、c 本机补跑、假 sysctl 至少被查 2 次（证明确实先超载、等过一轮再接）
mkdir -p $T/fbin; printf '#!/bin/bash\nf=%s/sysctl_n; n=$(cat $f 2> /dev/null || echo 0); echo $((n + 1)) > $f\n[ $n = 0 ] && printf "{ 99.0 99.0 99.0 }\\n4\\n" || printf "{ 0.1 0.1 0.1 }\\n4\\n"\n' $T > $T/fbin/sysctl; chmod +x $T/fbin/sysctl
touch $T/env75r_c; r=$(PATH=$T/fbin:$PATH S2A_REMOTE_LOAD_K=1.5 g o11b); nq=$(cat $T/sysctl_n 2> /dev/null || echo 0); rm -f $T/env75r_c $T/sysctl_n
ck "⑪b 远端排队时超载过、后跑完，只 c 自报 75 → c 照样退回本机补跑、绿（rc=${r}）" '[ $r = 0 ] && has "c $L skip= only= " && [ "$nq" -ge 2 ] && grep -q "只这几步" $T/o11b && tail -1 $T/o11b | grep -qF "门禁 绿"'

mkdir -p $T/rr/tools/bin; printf '#!/bin/sh\necho 9.9.9\n' > $T/rr/tools/bin/bash; chmod +x $T/rr/tools/bin/bash
r=$(g o4); rm -rf $T/rr/tools
ck "④ 远端工具链不同 → c / b 退回本机补跑（b 带 skip=k1 k2）、a 照跑、全绿退出 0、不碰 Air（rc=${r}）" '[ $r = 0 ] && ! grep -q "$T/rr" $T/trace && has "c $L skip= only= " && has "b $L skip=k1 k2 only= " && has "a $L skip= only= " && grep -q "^mini 不可用，.* 步退回本机补跑：mini 不可用（remote.sh rc=125" $T/o4 && tail -1 $T/o4 | grep -qF "门禁 绿：full 档" && grep -q "［本机补跑：mini 不可用］" $T/o4'
r=$(S2A_REMOTE=t@192.0.2.1 g o5)
ck "④ 远端连不上 → 退回本机补跑、绿、退出 0（rc=${r}）" '[ $r = 0 ] && ! grep -q "$T/rr" $T/trace && has "c $L skip= only= " && tail -1 $T/o5 | grep -qF "门禁 绿"'

# ④b mini 忙（三个满核槽都被活进程占着（10-29 起 mini 3 槽）、队列 3 秒没动）→ 退回本机补跑：c 在本机跑、写明排队超时
sleep 60 & sp=$!; for i in 1 2 3; do mkdir -p $T/logs/slot.local.$i; echo $sp > $T/logs/slot.local.$i/pid; done
r=$(S2A_REMOTE_JOB_S=3 g o8); kill $sp; rm -rf $T/logs/slot.local.*
ck "④b mini 忙 → 退回本机补跑、写排队超时、绿（rc=${r}）" '[ $r = 0 ] && grep -q "^mini 不可用，.*退回本机补跑：.*排队超时" $T/o8 && ! grep -q "$T/rr" $T/trace && has "c $L skip= only= " && has "a $L skip= only= " && tail -1 $T/o8 | grep -qF "门禁 绿"'
# ④c 远端磁盘不足（10-25 mini 只剩 213 M）→ 同 ④b：远端拒派、退回本机补跑、写「磁盘不足」
r=$(S2A_REMOTE_FREE_GB=5 g o8c)
ck "④c mini 磁盘不足 → 退回本机补跑、写磁盘不足、绿（rc=${r}）" '[ $r = 0 ] && grep -q "^mini 不可用，.*退回本机补跑：.*磁盘不足" $T/o8c && has "c $L skip= only= "'
# ④d 10-28 Air 退出门禁池：mini 连不上时即使另一台能用（GATE_ALT_REMOTE=local 模拟旧的 air 备胎）也不换，退回本机补跑
r=$(S2A_REMOTE=t@192.0.2.1 GATE_ALT_REMOTE=local g o9)
ck "④d mini 连不上 → 不换另一台、退回本机补跑（rc=${r}）" '[ $r = 0 ] && ! has "c $RW skip= only= " && has "c $L skip= only= " && ! grep -q "换 air" $T/o9 && tail -1 $T/o9 | grep -qF "门禁 绿"'
# ④e GATE_HOST=air → 拒绝、退出 2（门禁不在 Air 跑）
r=$(GATE_HOST=air bash tools/gate.sh > $T/o10 2>&1; echo $?)
ck "④e GATE_HOST=air → 拒绝、退出 2（rc=${r}）" '[ $r = 2 ] && grep -q "门禁不在 Air 跑" $T/o10'
# ④f 远端没就绪、同时本机有一步真红（b 的本机子项红）→ 真红优先：退出 1、结论「门禁 红」
touch $T/red_b_only; r=$(S2A_REMOTE=t@192.0.2.1 g o11); rm -f $T/red_b_only
ck "④f 退回本机补跑 + 本机子项真红 → 退出 1、门禁红（rc=${r}）" '[ $r = 1 ] && tail -1 $T/o11 | grep -qF "门禁 红"'''
# ④g GATE_FALLBACK_LOCAL=0 → 旧行为：环境未就绪、c 不补跑、退出 75
r=$(S2A_REMOTE=t@192.0.2.1 GATE_FALLBACK_LOCAL=0 g o11g)
ck "④g GATE_FALLBACK_LOCAL=0 → 环境未就绪、c 不补跑、退出 75（rc=${r}）" '[ $r = 75 ] && ! has "c $L skip= only= " && tail -1 $T/o11g | grep -qF "门禁 环境未就绪"'
# ④h mini 超载等降一直不接（10-29 总指挥）→ 不退回本机补跑（本机补跑同样不可信）：环境未就绪、c 不补跑、退出 75、写明门禁机超载
r=$(S2A_REMOTE_LOAD_K=0.0001 S2A_REMOTE_JOB_S=3 g o11h)
ck "④h mini 超载 → 环境未就绪、c 不补跑、退出 75、写明门禁机超载（rc=${r}）" '[ $r = 75 ] && ! has "c $L skip= only= " && grep -q "门禁机超载、本机补跑同样不可信" $T/o11h && ! grep -q "退回本机补跑" $T/o11h'
mkdir -p d; cp c/gate.sh d/gate.sh; sed_edit 's/^echo "c /echo "d /' d/gate.sh
r=$(g o6); rm -rf d
ck "⑤ 本机有、提交里没有的钩子 d → 远端算不出 → 红、不静默少跑（rc=${r}）" '[ $r = 1 ] && grep -q "^🔴 钩子 d/gate.sh［mini］.*算不出这一步" $T/o6 && tail -1 $T/o6 | grep -qF "跑了 6 步 / 应跑 6 步"'
echo v9 > c/ver; git add c/ver; git commit -qm ver; echo v10 > c/ver
r=$(g o7); git checkout -q c/ver
ck "⑤ 工作树跟踪文件与提交不同 → 整份本机跑（rc=${r}）" '[ $r = 0 ] && ! grep -q "$T/rr" $T/trace && tail -1 $T/o7 | grep -qF "整份本机跑：工作树的跟踪文件与待测提交"'

# ⑥ ship.sh：暂存 c/ver = v2（未提交）；先红后绿
git init -q --bare $T/origin.git; git remote add origin $T/origin.git; git push -q origin HEAD:main 2> /dev/null; git fetch -q origin
export S2A_REPO=$T/repo S2A_TRAIN_DIR=$T/train S2A_TRAIN_WT=$T/twt MERGE_OWNER=甲
git checkout -q -b f1; echo v2 > c/ver; git add c/ver; echo "改 c" > $T/msg; H0=$(git rev-parse HEAD); D0=$(git diff --cached)
touch $T/red_b_skip; : > $T/trace; bash tools/ship.sh $T/msg 说明 > $T/s1 2>&1; r=$?; rm -f $T/red_b_skip
ck "⑥ ship 红：没提交、HEAD 与暂存区原样、门禁在 mini 跑到暂存的新内容 v2（rc=${r}）" '[ $r = 1 ] && [ "$(git rev-parse HEAD)" = "$H0" ] && [ "$(git diff --cached)" = "$D0" ] && has "c $RW skip= only= v2" && [ -z "$(ls $T/train/queue 2> /dev/null)" ]'
: > $T/trace; bash tools/ship.sh $T/msg 说明 > $T/s2 2>&1; r=$?
ck "⑥ ship 绿：提交的树 = 门禁跑的树（远端 HEAD 的树）、入队（rc=${r}）" '[ $r = 0 ] && [ "$(git rev-parse HEAD^{tree})" = "$(git -C $RW rev-parse HEAD^{tree})" ] && [ "$(git rev-parse HEAD^)" = "$H0" ] && has "c $RW skip= only= v2" && [ -n "$(ls $T/train/queue)" ] && [ -z "$(git status --porcelain --untracked-files=no)" ]'

# ⑦ 列车：land 的门禁派 mini、远端工作树名 train
: > $T/trace; timeout 300 bash tools/train.sh once > $T/t1 2>&1
ck "⑦ 列车 land：门禁派 mini（c 在 rr/wt/train 跑）、合入" 'has "c $T/rr/wt/train skip= only= v2" && grep -q "🟢 已合入 f1" $T/train/inbox/甲.log && grep "已合入 f1" $T/train/inbox/甲.log | grep -qF "mini 4 步"'

# ⑦b 快档用自己的远端工作树（TRAIN_RN=train-fast，常驻列车的快档循环设它）：不和慢档抢「远端工作树 train」那把锁
git checkout -q -b f2; echo v3 > c/ver; git add c/ver; bash tools/ship.sh $T/msg 说明 > $T/s3 2>&1
: > $T/trace; TRAIN_RN=train-fast timeout 300 bash tools/train.sh once > $T/t2 2>&1
ck "⑦b 快档门禁派 mini 用远端工作树 train-fast（c 在 rr/wt/train-fast 跑到 v3）、合入" 'has "c $T/rr/wt/train-fast skip= only= v3" && grep -q "🟢 已合入 f2" $T/train/inbox/甲.log'

[ $bad = 0 ] && echo "gate_mini 单测全过" || { echo "gate_mini 单测有不通（KEEP=1 保留 ${T}）"; exit 1; }
