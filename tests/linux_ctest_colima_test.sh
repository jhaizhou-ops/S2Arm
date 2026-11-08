#!/bin/bash
# 安卓 Linux CTest 起 colima：单实例锁 + 环境没备好退 75（android/linux_ctest.sh；假 colima 放 PATH 最前，不碰真虚拟机，约 15 秒）：
#   bash tests/linux_ctest_colima_test.sh
# 10-29 起因：colima 实例被删后，列车门禁每批 colima start 一次（建实例要下载约 600 MB 镜像），600 秒被杀、半截下载作废；
#   同时安卓线人工重建也在 start，两边共用同一个 .downloading 文件互相删改，谁也起不来，列车连红。
# 期望（按规则手写）：
#   ① 没有实例 default → 退 75、点名「没有 colima 实例」、一次 start 都不调
#   ② 有实例没在跑、没人持锁 → start 1 次，CTest 通过退 0，锁目录用完删掉
#   ③ 别人持锁（活进程）、2 秒后虚拟机起好 → 自己不 start，等到后退 0
#   ④ 锁里是死进程 → 清掉陈旧锁，start 1 次，退 0
#   ⑤ 别人持锁、一直没起好、S2A_COLIMA_WAIT_S=5 → 退 75、点名「等了」
#   ⑥ 两份同时跑（虚拟机没在跑、start 要 3 秒）→ 合计只 start 1 次，两份都退 0
#   ⑦ 虚拟机里缺 cmake（CTest 段退 75）→ 整体退 75，不是红
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0; SL=
trap '[ -n "$SL" ] && kill $SL 2> /dev/null; rm -rf "$T"' EXIT
[ "$(uname -s)" = Darwin ] || { echo "跳过：只在 macOS 上走 colima"; exit 75; }   # 环境未就绪、不当绿；Linux 自检按 tools/contrib_tools.tsv 记「交 Mac 门禁」，不选这一步
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
mkdir -p $T/bin; cat > $T/bin/colima <<'EOF'
#!/bin/bash
case $1 in
  status) [ -f "$STUB/up" ];;
  list) echo "PROFILE    STATUS"; [ -f "$STUB/inst" ] && echo "default    Stopped"; exit 0;;
  start) echo start >> "$STUB/starts"; sleep "${STUB_START_S:-0}"; touch "$STUB/up";;
  ssh) exit "${STUB_SSH_RC:-0}";;
esac
EOF
chmod +x $T/bin/colima
reset() { rm -rf $T/s $T/ch; mkdir -p $T/s $T/ch; [ "${1:-}" = inst ] && touch $T/s/inst; return 0; }
# HOME 给仓库的上一级：linux_ctest.sh 要求仓库在家目录下（colima 只挂家目录）；mini 门禁 HOME 是远端假家目录、工作树不在它下面（10-29 列车退回：7 条都红在「仓库不在家目录下」）
run() { HOME=$(dirname "$H") PATH=$T/bin:$PATH STUB=$T/s COLIMA_HOME=$T/ch bash $H/android/linux_ctest.sh 2>&1; }
starts() { grep -c start $T/s/starts 2> /dev/null || echo 0; }
reset; o=$(run); rc=$?
ck "① 没有实例 → 退 75、点名没有实例、不 start（rc=${rc}，$(starts) 次；$(tail -1 <<< "$o" | cut -c1-80)）" '[ $rc = 75 ] && grep -q "没有 colima 实例 default" <<< "$o" && [ "$(starts)" = 0 ]'
reset inst; o=$(run); rc=$?
ck "② 有实例没在跑 → start 1 次、退 0、锁删掉（rc=${rc}，$(starts) 次）" '[ $rc = 0 ] && [ "$(starts)" = 1 ] && [ ! -e $T/ch/s2a-start.lock ]'
reset inst; sleep 30 & SL=$!; mkdir $T/ch/s2a-start.lock; echo $SL > $T/ch/s2a-start.lock/pid; ( sleep 2; touch $T/s/up ) &
o=$(run); rc=$?; kill $SL 2> /dev/null; SL=
ck "③ 别人持锁、2 秒后起好 → 不 start、等到后退 0（rc=${rc}，$(starts) 次）" '[ $rc = 0 ] && [ "$(starts)" = 0 ]'
reset inst; mkdir $T/ch/s2a-start.lock; echo 99999 > $T/ch/s2a-start.lock/pid; kill -0 99999 2> /dev/null && echo "（注意：pid 99999 恰好活着，④ 结果不作数）"
o=$(run); rc=$?
ck "④ 锁里是死进程 → 清陈旧锁、start 1 次、退 0（rc=${rc}，$(starts) 次）" '[ $rc = 0 ] && [ "$(starts)" = 1 ] && [ ! -e $T/ch/s2a-start.lock ]'
reset inst; sleep 30 & SL=$!; mkdir $T/ch/s2a-start.lock; echo $SL > $T/ch/s2a-start.lock/pid
o=$(S2A_COLIMA_WAIT_S=5 run); rc=$?; kill $SL 2> /dev/null; SL=
ck "⑤ 别人持锁一直没起好、等 5 秒 → 退 75、点名等了（rc=${rc}，$(starts) 次；$(tail -1 <<< "$o" | cut -c1-80)）" '[ $rc = 75 ] && grep -q "等了" <<< "$o" && [ "$(starts)" = 0 ]'
reset inst; export STUB_START_S=3; run > $T/o1 & p1=$!; run > $T/o2 & p2=$!; wait $p1; r1=$?; wait $p2; r2=$?; unset STUB_START_S
ck "⑥ 两份同时跑 → 合计 start 1 次、两份都退 0（rc=${r1}/${r2}，$(starts) 次）" '[ $r1 = 0 ] && [ $r2 = 0 ] && [ "$(starts)" = 1 ]'
reset inst; touch $T/s/up; o=$(STUB_SSH_RC=75 run); rc=$?
ck "⑦ 虚拟机里缺编译工具 → 退 75（rc=${rc}；$(tail -1 <<< "$o" | cut -c1-80)）" '[ $rc = 75 ] && grep -q "环境未就绪" <<< "$o"'
[ $bad = 0 ] && echo "linux_ctest_colima 单测全过" || { echo "linux_ctest_colima 单测有不通"; exit 1; }
