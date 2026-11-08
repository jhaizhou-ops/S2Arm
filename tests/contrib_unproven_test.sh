#!/bin/bash
# contrib_check 红步与基线对照（#783 11-03 合入线答 1：摘要把「本机红、与基线同、未证」单列、写成机读行）：临时仓库 + 桩门禁，约 3 秒：bash tests/contrib_unproven_test.sh
#   桩门禁按树里的 stub_results（步<TAB>要打的行）列步骤、出结论：分叉点那份与本支那份不同，@ROOT@ 换成门禁所在的树（错误原文里带树路径，核路径换算）；
#   同真门禁，请求的步有一个不在清单里就整次不跑、退出 2（tools/gate.sh「自检请求的步骤未在本次清单中」）。
#   s2 的错误原文还带每次都变的东西（@HEAD@ = 所在树的提交短号，@FREE@ = 7 位随机数，同本机 stat 的剩余块数）：要换掉才对得上；
#   s3 的乙项两边差在 16 位着色器键上：不换，照样算新红。
#   期望按规则手写（本支 8 步：s1 绿；s2 红、明细与基线逐项同；s3 红、比基线多一项；s4 红、基线绿；s5 红、两边都取不出明细；s6 红、基线没有这一步；
#   s7 跑到门禁时限（rc=124，超 600 秒）；s8 自己退 124、没到上限，明细与基线同）：
#   ①–③ 设 CONTRIB_BASE_RERUN=1：① 退出 1、结论红不变；门禁在分叉点的临时工作树里先列一次步骤、再只跑红而基线也有、没超时的 5 步（s6 基线没有、s7 超时，都不请求）；跑完临时工作树清掉
#   ② 摘要：新红 3 步、与基线同红 3 步、本机超时没重跑 1 步；新红逐步写原因（多出的失败项原文与项数 / 基线这一步绿 / 基线没有这一步）
#   ③ 机读行恰好四行：未证<TAB>单测 s2<TAB>逐项相同<TAB>提交全号<TAB>基线全号；s5 只比到整步；s7 超时；s8 逐项相同
#   ④ 缺省（不设 CONTRIB_BASE_RERUN；环境里设了也由 run 先清掉）：不再跑门禁、写「没对照」并列出本机红的 7 步（步名取到「<数字> 秒」前，明细里的「秒」不算）、提示怎么对照、没有机读行，退出码不变；
#   ⑤ 设 1 但全绿：不对照、摘要没有对照行；⑥ 设 1 但树里没有 tools/known_red.py：写「没对照」、不建临时工作树，退出码不变。不联网、不碰真列车目录（S2A_TRAIN_DIR 指临时目录）
# 临时目录取物理路径（pwd -P）：macOS 上 mktemp 给 /var/…，git 与桩门禁看到的是 /private/var/…，① 靠路径分本支 / 基线那几次调用（11-04 mini 退回 #1476）
# 计数一律 grep -c：macOS 的 wc -l 输出左边补空格，「= 1」比不上（11-04 mini 第二次退回 #1476）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
R=$T/repo; mkdir -p $R/tools $T/tmp; git -C $R init -q; git -C $R config user.email t@t; git -C $R config user.name t
cp "$H/tools/contrib_check.sh" "$H/tools/idle_timeout.sh" "$H/tools/gate_plan.sh" "$H/tools/known_red.py" $R/tools/; : > $R/tools/contrib_layer2.tsv; : > $R/tools/contrib_tools.tsv
printf '#!/bin/bash\nexit 0\n' > $R/tools/doctor.sh
cat > $R/tools/gate.sh <<'G'
#!/bin/bash
printf '%s\t%s\t%s\n' "$PWD" "${GATE_LIST:-}" "${GATE_RERUN:-}" >> "$STUB_CALLS"
if [ "${GATE_LIST:-}" = 1 ]; then cut -f1 stub_results | uniq; exit 0; fi
IFS=$'\t' read -ra want <<< "${GATE_RERUN:-}"
for w in "${want[@]}"; do cut -f1 stub_results | grep -qFx "$w" || { echo "自检请求的步骤未在本次清单中：${w}（结论不完整）" >&2; exit 2; }; done
[ -n "${STUB_GREEN:-}" ] && { for i in 1 2 3 4 5 6 7 8; do echo "🟢 单测 s$i 0 秒：过"; done; echo "门禁 绿"; exit 0; }
sed "s#@ROOT@#$PWD#g; s#@HEAD@#$(git rev-parse --short=9 HEAD)#g; s#@FREE@#$((1000000 + RANDOM))#g" stub_results | awk -F'\t' -v w="${GATE_RERUN:-}" 'BEGIN { n = split(w, a, "\t"); for (i = 1; i <= n; i++) k[a[i]] = 1 }
  k[$1] { print substr($0, length($1) + 2); if ($2 ~ /^🔴/) r = 1 } END { print (r ? "门禁 红" : "门禁 绿"); exit r }'
G
cat > $R/stub_results <<'B'
单测 s1	🟢 单测 s1 0 秒：过
单测 s2	🔴 单测 s2 3 秒（rc=1）：甲有不通
单测 s2	    | 甲项：@ROOT@/tests/s2.sh 坏了，合进 main @HEAD@、剩余 @FREE@ 块（退出 1）
单测 s3	🔴 单测 s3 0 秒（rc=1）：乙有不通
单测 s3	    | 乙项：键 0123456789abcdef 坏了（退出 1）
单测 s4	🟢 单测 s4 0 秒：过
单测 s5	🔴 单测 s5 0 秒（rc=1）：有不通
单测 s7	🔴 单测 s7 603 秒（rc=124，超 600 秒）：跑到时限
单测 s8	🔴 单测 s8 5 秒（rc=124，没到 600 秒上限：是这一步自己退出 124）：自己退 124
单测 s8	    | 戊项：坏了（退出 124）
B
echo 1 > $R/tools/x.sh; git -C $R add -A; git -C $R commit -qm base; B=$(git -C $R rev-parse HEAD)
cat > $R/stub_results <<'N'
单测 s1	🟢 单测 s1 0 秒：过
单测 s2	🔴 单测 s2 1 秒（rc=1）：甲有不通
单测 s2	    | 甲项：@ROOT@/tests/s2.sh 坏了，合进 main @HEAD@、剩余 @FREE@ 块（退出 1）
单测 s3	🔴 单测 s3 0 秒（rc=1）：乙丙有不通
单测 s3	    | 乙项：键 fedcba9876543210 坏了（退出 1） / 丙项：坏了（退出 1）
单测 s4	🔴 单测 s4 0 秒（rc=1）：有不通
单测 s5	🔴 单测 s5 0 秒（rc=1）：有不通
单测 s6	🔴 单测 s6 0 秒（rc=1）：新单测红，用时 12 秒
单测 s6	    | 丁项：坏了（退出 1）
单测 s7	🔴 单测 s7 603 秒（rc=124，超 600 秒）：跑到时限
单测 s8	🔴 单测 s8 5 秒（rc=124，没到 600 秒上限：是这一步自己退出 124）：自己退 124
单测 s8	    | 戊项：坏了（退出 124）
N
echo 2 > $R/tools/x.sh; git -C $R commit -qam change; HD=$(git -C $R rev-parse HEAD)
run() { : > $T/calls; (cd $R && env -u CONTRIB_BASE_RERUN S2A_TRAIN_DIR=$T/no-train CONTRIB_HOST=local TMPDIR=$T/tmp STUB_CALLS=$T/calls "$@" timeout 60 bash tools/contrib_check.sh --base $B > $T/out 2>&1); echo $?; }
sm() { sed -n '/^### 自检/,$p' $R/build/contrib_check/summary.md; }
r=$(run CONTRIB_BASE_RERUN=1); S=$(sm)
ck "① 退出 ${r}（期望 1）、结论红" '[ "$r" = 1 ] && grep -q "结论：\*\*红\*\*" <<< "$S"'
runs() { grep -vc "	1	" $T/calls; }   # 第 2 列 = GATE_LIST：真跑（不是列步骤）的次数
c3=$(grep -v "	1	" $T/calls | sed -n 2p); c3d=$(cut -f1 <<< "$c3"); c3s=$(cut -f3- <<< "$c3")
ck "① 门禁真跑 2 次（实 $(runs)）：本支 8 步一次；分叉点临时工作树先列步骤一次、再只跑红而基线也有、没超时的 5 步（实 ${c3s}）" '[ "$(runs)" = 2 ] && [ "$(grep "	1	" $T/calls | grep -vc "^$R	")" = 1 ] && [ "$c3d" != "$R" ] && [ "$c3s" = "$(printf "单测 s2\t单测 s3\t单测 s4\t单测 s5\t单测 s8")" ]'
ck "① 跑完临时工作树清掉（git worktree list 只剩本仓库、TMPDIR 下没有 contrib-base.*）" '[ "$(git -C $R worktree list | grep -c .)" = 1 ] && [ -z "$(ls $T/tmp)" ]'
ck "② 新红 3 步、与基线同红 3 步、本机超时没重跑 1 步" 'grep -q "：新红 3 步、与基线同红 3 步、本机超时没重跑 1 步$" <<< "$S"'
ck "② 新红逐步写原因：s3 多出 2 项（16 位键不同的乙项 + 丙项）、s4 基线绿、s6 基线没有这一步（实 $(grep "^- 新红" <<< "$S")）" '[ "$(grep "^- 新红" <<< "$S")" = "- 新红（基线上对不上：本 PR 引入的，或基线这一步跑法不同；要修或在 PR 里说明）：单测 s3（多出基线没有的失败项：乙项：键 fedcba9876543210 坏了（退出 1） 等 2 项）；单测 s4（基线这一步绿）；单测 s6（基线没有这一步）；" ]'
want=$(for x in 's2	逐项相同' 's5	只比到整步' 's7	超时' 's8	逐项相同'; do printf '未证\t单测 %s\t%s\t%s\n' "$x" "$HD" "$B"; done)
ck "③ 机读行恰好四行（s2 逐项相同：树路径、提交短号、大数换掉后才对得上；s5 只比到整步；s7 超时、没在基线重跑；s8 自己退 124、照常对照）" '[ "$(grep "^未证	" <<< "$S")" = "$want" ]'
r=$(run); S=$(sm)
ck "④ 缺省不对照：退出 ${r}（期望 1）、门禁只真跑 1 次、写没对照并列出本机红的 5 步、没有机读行（实 $(grep "^- 红步与基线对照" <<< "$S")）" '[ "$r" = 1 ] && [ "$(runs)" = 1 ] && [ "$(grep "^- 红步与基线对照" <<< "$S")" = "- 红步与基线对照：没对照（设 CONTRIB_BASE_RERUN=1 在分叉点只重跑这几步、分出新红与未证）：本机红 7 步：单测 s2；单测 s3；单测 s4；单测 s5；单测 s6；单测 s7；单测 s8；" ] && ! grep -q "^未证	" <<< "$S" && [ -z "$(ls $T/tmp)" ]'
r=$(run STUB_GREEN=1 CONTRIB_BASE_RERUN=1); S=$(sm)
ck "⑤ 全绿：退出 ${r}（期望 0）、门禁只真跑 1 次、摘要没有对照行" '[ "$r" = 0 ] && [ "$(runs)" = 1 ] && ! grep -q "红步与基线对照" <<< "$S"'
# ⑦ 基线那一步没跑全（#1553）：基线 s9 退 0 但打了「待宿主证」机读行（同安卓钩子遇 APK 准备持锁早退）、本支 s9 红 →
#   不算「基线这一步绿」的新红，记未证「基线没跑全（待安卓宿主证：apk）」；摘要「新红 0 步、与基线同红 0 步、基线这一步没跑全 1 步」
printf '单测 s1\t🟢 单测 s1 0 秒：过\n单测 s9\t🟢 单测 s9 0 秒：过\n单测 s9\t待宿主证\t安卓宿主\tapk\t单测 s9\n' > $R/stub_results; git -C $R commit -qam b2; B2=$(git -C $R rev-parse HEAD)
printf '单测 s1\t🟢 单测 s1 0 秒：过\n单测 s9\t🔴 单测 s9 0 秒（rc=1）：有不通\n' > $R/stub_results; git -C $R commit -qam h2; H2=$(git -C $R rev-parse HEAD)
: > $T/calls; (cd $R && env -u CONTRIB_BASE_RERUN S2A_TRAIN_DIR=$T/no-train CONTRIB_HOST=local TMPDIR=$T/tmp STUB_CALLS=$T/calls CONTRIB_BASE_RERUN=1 timeout 60 bash tools/contrib_check.sh --base $B2 > $T/out 2>&1); S=$(sm)
ck "⑦ 基线那一步打了待宿主证：不算新红（实 $(grep "^- 红步与基线对照" <<< "$S" | sed 's/^.*）：//')）" 'grep -q "：新红 0 步、与基线同红 0 步、基线这一步没跑全 1 步$" <<< "$S"'
ck "⑦ 未证机读行写基线没跑全" '[ "$(grep "^未证	" <<< "$S")" = "$(printf "未证\t单测 s9\t基线没跑全（待安卓宿主证：apk）\t%s\t%s" "$H2" "$B2")" ]'
git -C $R rm -q tools/known_red.py; git -C $R commit -qm no-kr
r=$(run CONTRIB_BASE_RERUN=1); S=$(sm)
ck "⑥ 没有 known_red.py：退出 ${r}（期望 1）、门禁只真跑 1 次、写没对照、不建临时工作树" '[ "$r" = 1 ] && [ "$(runs)" = 1 ] && grep -q "^- 红步与基线对照：没对照（没有 tools/known_red.py）$" <<< "$S" && [ -z "$(ls $T/tmp)" ]'
[ $bad = 0 ] && echo "contrib_unproven 单测全过" || { echo "contrib_unproven 单测有不通"; exit 1; }
