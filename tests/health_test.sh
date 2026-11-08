#!/bin/bash
# Mac 健康表单测（造局目录 + 假 Mac 入口，秒级）：bash tests/health_test.sh
# 期望按 health_table.py 头注释的规则手算：同数不退；渲染遍 +3（> 10×0.1+2=3）判退、+2 不退；基线到 MARK 候选没到判退并列「MARK 退」；
# 绘制差 > 30% 判不可比（不退）；不可比但崩增加照样判退；A/A 波动大于 20% 的列只观察；分配闸门转红判退；缺 Mac 入口报红退出 2
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
# 造一款：$1 目录 $2 款 $3 MARK 帧（0 = 没有）$4 渲染遍 $5 绘制 $6 gen0 是否在窗口里涨（0/1）
mk() { mkdir -p $1/$2; awk -v p=$4 -v d=$5 -v g=$6 -v mk=$3 'BEGIN{print "frame\twall_us\talloc_b\tgc0\tgc1\tgc2\trb_us\tdraw_n\tpass_n\tupload_n\trw_kb\tshader_miss\tgc_pause_us"; c=0; for(i=1;i<=1200;i++){ s=0; if(g&&i==mk+11){c=1; s=5000}; printf "%d\t33333\t100\t%d\t0\t0\t0\t%d\t%d\t4\t20480\t0\t%d\n", i, c, d, p, s} }' > $1/$2/frames.tsv
  { echo 'S2A 就绪'; [ "$3" -gt 0 ] && echo "S2A 标记 MARK：帧 $3"; } > $1/$2/host.log; }
tb() { python3 $H/tools/health_table.py "$@" --aa=$T/aa.tsv > $T/tb.out 2>&1; echo $?; }
: > $T/aa.tsv
mkdir -p $T/empty-a $T/empty-b
ck "A/B 全无局 → 未测退出 2，不报绿色" '[ "$(tb $T/empty-a $T/empty-b)" = 2 ] && grep -q 未测 $T/tb.out && ! grep -q 🟢 $T/tb.out'
mkdir -p $T/nodata-a/acnh $T/nodata-b/acnh
for d in $T/nodata-a $T/nodata-b; do printf 'frame\tpass_n\tupload_n\trw_kb\tdraw_n\tshader_miss\n' > $d/acnh/frames.tsv; : > $d/acnh/host.log; done
ck "只有表头 → 未测退出 2" '[ "$(tb $T/nodata-a $T/nodata-b)" = 2 ] && grep -q 未测 $T/tb.out'
for row in $'1\t\t\t\t\t' $'1\tbad\tbad\tbad\tNaN\tbad'; do
  for d in $T/nodata-a $T/nodata-b; do printf 'frame\tpass_n\tupload_n\trw_kb\tdraw_n\tshader_miss\n%s\n' "$row" > $d/acnh/frames.tsv; done
  ck "计数空白或非数字 → 未测退出 2" '[ "$(tb $T/nodata-a $T/nodata-b)" = 2 ] && grep -q 未测 $T/tb.out && ! grep -q 🟢 $T/tb.out'
done
printf 'frame\tshader_miss\n1\t3\n' > $T/nodata-b/acnh/frames.tsv
ck "其他读数不可用但现翻实读 3 → 红项优先退出 1" '[ "$(tb $T/nodata-a $T/nodata-b)" = 1 ] && grep -q 变差 $T/tb.out'
mk $T/a acnh 100 10 500 0;
ck "只有一侧缺局 → 退出 1" '[ "$(tb $T/a $T/empty-b)" = 1 ] && grep -q 缺局 $T/tb.out'
mk $T/a acnh 100 10 500 0; mk $T/b acnh 100 10 500 0;                    ck "同数 → 不退（退出 0）" '[ "$(tb $T/a $T/b)" = 0 ] && grep -q "acnh.*不退" $T/tb.out'
mk $T/b acnh 100 14 500 0;                                               ck "渲染遍 10→14（> 3）→ 变差（退出 1）" '[ "$(tb $T/a $T/b)" = 1 ] && grep -q "变差.*渲染遍" $T/tb.out'
mk $T/b acnh 100 12 500 0;                                               ck "渲染遍 10→12（≤ 3）→ 不退" '[ "$(tb $T/a $T/b)" = 0 ]'
mk $T/b acnh 0 10 500 0;                                                 ck "基线到 MARK、候选没到 → 变差 + MARK 退" '[ "$(tb $T/a $T/b)" = 1 ] && grep -q "^MARK 退：acnh" $T/tb.out'
mk $T/b acnh 100 30 700 0;                                               ck "绘制 500→700（> 30%）→ 不可比、不退" '[ "$(tb $T/a $T/b)" = 0 ] && grep -q 不可比 $T/tb.out'
echo CRASH >> $T/b/acnh/host.log;                                        ck "不可比但崩增加 → 变差" '[ "$(tb $T/a $T/b)" = 1 ]'
mk $T/b acnh 100 10 500 1;                                               ck "分配闸门 绿→红 → 变差" '[ "$(tb $T/a $T/b)" = 1 ] && grep -q 分配闸门转红 $T/tb.out'
mk $T/x acnh 100 10 500 0; mk $T/y acnh 100 13 500 0; printf "$T/x\t$T/y\n" > $T/aa.tsv   # A/A 波动 3 > 10×20% → 渲染遍只观察
mk $T/b acnh 100 16 500 0;                                               ck "A/A 波动大于 20% 的列只观察 → 渲染遍 +6 不退" '[ "$(tb $T/a $T/b)" = 0 ] && grep -q "只观察：渲染遍" $T/tb.out'
: > $T/aa.tsv
# 采集：假 Mac 入口写一局；没有入口 → 退出 2
mkdir -p $T/repo/tools $T/repo/native $T/roots/acnh@1/x; cp $H/tools/mac_health.sh $H/tools/host_build.sh $H/tools/clonedir.py $H/tools/cost_log.sh $H/tools/zero_gate.py $H/tools/mac_slot.sh $H/tools/mac_slot_frozen.sh $H/tools/s2a_machine.sh $T/repo/tools/; export S2A_MAC_SLOT_DIR=$T/mslot S2A_MAC_SLOT_BIN=$T/repo/tools/mac_slot.sh; ln -s acnh@1 $T/roots/acnh@现行; echo in > $T/roots/acnh@1/x/f
(cd $T/repo && git init -q); out=$(cd $T/repo && HEALTH_ROOT=$T/roots bash tools/mac_health.sh $T/h0 acnh 2>&1); r=$?
ck "没有 runtime/run_mac.sh → 报红退出 2" '[ $r = 2 ] && grep -q "没有 Mac 入口" <<< "$out"'
printf 'host:\n\t@echo "$$S2A_CS" >> builds.log\n' > $T/repo/Makefile   # 替身构建：真编一次记一行（带的 S2A_CS）
cat > $T/repo/native/run_mac.sh <<'EOF'
echo "${S2A_HOST_PREBUILT:-}" > $2/prebuilt; [ -f "$S2A_IN/x/f" ] || exit 9; [ -n "${FAKE_SLEEP:-}" ] && sleep "$FAKE_SLEEP"; echo "${S2A_SCREEN_W:-无}" > $2/sw_env; printf 'S2A 就绪\nS2A 标记 MARK：帧 10\n' > $2/host.log; cp "$S2A_IN/../../frames_src.tsv" $2/frames.tsv 2>/dev/null || printf 'frame\twall_us\n1\t33333\n' > $2/frames.tsv
EOF
(cd $T/repo && COST_LINE=测试 COST_WHY=健康表单测 S2A_COST_TSV=$T/cost.tsv HEALTH_ROOT=$T/roots bash tools/mac_health.sh $T/h1 acnh > $T/h1.out 2>&1)
ck "假入口：读到快照输入、局目录有 host.log、快照已删、done 在" 'grep -q "acnh rc=0" $T/h1.out && [ -s $T/h1/acnh/host.log ] && [ ! -d $T/h1/acnh/in_snap ] && [ -f $T/h1/done ]'
ck "宿主在局槽外编一次（带 S2A_CS=1）、局里收到 S2A_HOST_PREBUILT=1" '[ "$(cat $T/repo/builds.log)" = 1 ] && [ "$(cat $T/h1/acnh/prebuilt)" = 1 ]'
ck "成本账本记一行：线 测试 / 类别 mac / 款 acnh / 为什么 健康表单测 / 结果 rc=0" 'awk -F"\t" "NR > 1" $T/cost.tsv | grep -q "	测试	mac	acnh	健康表单测	[0-9]*	rc=0"'
ck "收局跑必须为 0 闸门：写 zero.txt（假入口没有汇总行 → 未测项列出）" '[ -s $T/h1/acnh/zero.txt ] && grep -q "必须为 0" $T/h1/acnh/zero.txt'
ck "HEALTH_SCREEN_W 给了 → 屏宽照传" '(cd $T/repo && HEALTH_SCREEN_W=2346 HEALTH_ROOT=$T/roots bash tools/mac_health.sh $T/h3 acnh > /dev/null 2>&1) && [ "$(cat $T/h3/acnh/sw_env)" = 2346 ]'
ck "不给 HEALTH_SCREEN_W → 缺省全能力屏宽 2346（11-01 总指挥：验收 / 复判局五问满屏格才作数）" '[ "$(cat $T/h1/acnh/sw_env)" = 2346 ]'
ck "显式 HEALTH_NATIVE=1 → 原比例 1920" '(cd $T/repo && HEALTH_NATIVE=1 HEALTH_ROOT=$T/roots bash tools/mac_health.sh $T/h4 acnh > /dev/null 2>&1) && [ "$(cat $T/h4/acnh/sw_env)" = 1920 ]'
ck "墙钟上限随局时走：HEALTH_SEC=1 → 上限 11 秒，入口睡 13 秒被掐（原写死 290 秒、长局时被提前掐）" '(cd $T/repo && FAKE_SLEEP=13 HEALTH_SEC=1 HEALTH_ROOT=$T/roots bash tools/mac_health.sh $T/h5 acnh > $T/h5.out 2>&1); ! grep -q "acnh rc=0" $T/h5.out'
ck "没有现行产物根的款跳过、不算错" '(cd $T/repo && HEALTH_ROOT=$T/roots bash tools/mac_health.sh $T/h2 mk8d > /dev/null 2>&1) && [ -f $T/h2/mk8d/skip ]'
rm -rf $T; [ $bad = 0 ] && echo "health 单测全过" || { echo "health 单测有不通"; exit 1; }
