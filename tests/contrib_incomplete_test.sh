#!/bin/bash
# contrib_check 结论判据（10-27 交付线：外层被停后远端步骤陆续被杀，收尾「跑了 9 步；绿 0、红 0」照样 rc=0、cc_enqueue 推送入队）：
#   临时仓库 + 桩门禁（列 9 步）。期望按规则手写：
#   ① 9 步全出 🟢 → 退出 0、结论绿；② 9 步一个结论都没出、门禁 rc=0 → 退出 2、结论「不完整」、点明「只出 0 个结论」；
#   ②b 0 个结论、门禁日志有「门禁令牌：本步已排…」→ 退出 2、写「环境未就绪：门禁一步结论都没出」、把排队行带出来（11-04 mini 令牌漏一半，两份自检空跑 45 分钟）
#   ③ 跑到一半收到 TERM → 退出 130、写「自检被中断」，不写结论绿。不联网、不碰真列车目录（S2A_TRAIN_DIR 指临时目录）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
R=$T/repo; mkdir -p $R/tools; git -C $R init -q; git -C $R config user.email t@t; git -C $R config user.name t
cp "$H/tools/contrib_check.sh" "$H/tools/idle_timeout.sh" $R/tools/; : > $R/tools/contrib_layer2.tsv; : > $R/tools/contrib_tools.tsv
printf '#!/bin/bash\nexit 0\n' > $R/tools/doctor.sh
cat > $R/tools/gate.sh <<'G'
#!/bin/bash
if [ "${GATE_LIST:-}" = 1 ]; then for i in 1 2 3 4 5 6 7 8 9; do echo "单测 s$i"; done; exit 0; fi
case ${STUB:-} in
  green) for i in 1 2 3 4 5 6 7 8 9; do echo "🟢 单测 s$i"; done; echo "门禁 绿";;
  empty) echo "门禁 结束";;
  queued) echo "门禁令牌：本步已排 60 秒，8 个全被占（桩）" >&2; echo "门禁 结束";;
  sleep) : > "${STUB_MARK:-/dev/null}"; sleep 3; echo "门禁 结束";;   # 落标记：自检已装好 trap、真在跑步骤
esac; exit 0
G
echo 1 > $R/tools/x.sh; git -C $R add -A; git -C $R commit -qm base; B=$(git -C $R rev-parse HEAD)
echo 2 > $R/tools/x.sh; git -C $R commit -qam change
run() { (cd $R && env S2A_TRAIN_DIR=$T/no-train CONTRIB_HOST=local "$@" timeout 60 bash tools/contrib_check.sh --base $B > $T/out 2>&1); echo $?; }
r=$(run STUB=green); ck "① 9 步全绿：退出 ${r}（期望 0）、结论绿" '[ "$r" = 0 ] && grep -q "结论：\*\*绿\*\*" $T/out'
r=$(run STUB=empty); ck "② 9 步 0 个结论：退出 ${r}（期望 2）、结论不完整、点明只出 0 个结论" '[ "$r" = 2 ] && grep -q "结论：\*\*不完整\*\*" $T/out && grep -q "只出 0 个结论" $T/out'
r=$(run STUB=queued); ck "②b 0 个结论且卡在令牌排队：退出 ${r}（期望 2）、写明环境未就绪、带出排队行" '[ "$r" = 2 ] && grep -q "环境未就绪：门禁一步结论都没出" $T/out && grep -q "门禁令牌：本步已排 60 秒" $T/out'
(cd $R && exec env S2A_TRAIN_DIR=$T/no-train CONTRIB_HOST=local STUB=sleep STUB_MARK=$T/started bash tools/contrib_check.sh --base $B > $T/out3 2>&1) & P=$!
# 等桩步骤真开跑再发 TERM（原先固定 sleep 1：门禁机一忙，trap 还没装好就收到 TERM，按缺省退 143，10-29 mini 上退回 868 / #955）
for _ in $(seq 1 200); do [ -e $T/started ] && break; sleep 0.1; done
kill -TERM $P; wait $P; r=$?
ck "③ 中途 TERM：退出 ${r}（期望 130）、写「自检被中断」、没有结论绿" '[ "$r" = 130 ] && grep -q "自检被中断" $T/out3 && ! grep -q "结论：\*\*绿\*\*" $T/out3'
# ④ 多工具映射（10-27：rewrite_* 同时要 Python 包与改写器固定依赖）：表里「单测 s1	甲,乙」、体检报「缺：乙」→ s1 记「缺工具没跑」、结论不完整（退出 2）；
#   不缺时照跑、全绿（退出 0）
printf '单测 s1\t甲,乙\n' > $R/tools/contrib_tools.tsv; git -C $R commit -qam tools-map
printf '#!/bin/bash\necho "缺：乙"\nexit 1\n' > $R/tools/doctor.sh; git -C $R commit -qam miss
r=$(run STUB=green); ck "④ 缺多工具里的一个：退出 ${r}（期望 2）、s1 记缺工具没跑（缺 乙）" '[ "$r" = 2 ] && grep -q "缺工具没跑：单测 s1（缺 乙）" $T/out'
printf '#!/bin/bash\nexit 0\n' > $R/tools/doctor.sh; git -C $R commit -qam nomiss
r=$(run STUB=green); ck "④ 都不缺：退出 ${r}（期望 0）、没有缺工具没跑" '[ "$r" = 0 ] && ! grep -q "缺工具没跑" $T/out'
[ $bad = 0 ] && echo "contrib_incomplete 单测全过" || { echo "contrib_incomplete 单测有不通"; exit 1; }
