#!/bin/bash
# 同包开关 A/B 一键登记单测（tools/ab.sh；临时调度目录，夹具用 tests/fixtures/alloc_gate 两局真实局）：bash tests/ab_test.sh
#   期望：不给开关 / 不设 MERGE_OWNER → 拒；report：两局都有结果 → 两行（A、B 各带包号、开关、frame_gate 同口径读回 / 帧数 / 每帧分配 / GC 可玩段最长）、退出 0；
#   B 局还没出结果 → 「未出结果」、退出非 0（--wait=0 不等）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0; trap 'rm -rf "$T"' EXIT
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
export S2A_SCHED_DIR=$T/sched; mkdir -p $T/sched/jobs $T/sched/pkgs
o1=$(MERGE_OWNER=测试 bash $H/tools/ab.sh acnh 2>&1); r1=$?; o2=$(bash $H/tools/ab.sh acnh X=1 2>&1); r2=$?
ck "不给开关 → 拒（rc=${r1}）；不设 MERGE_OWNER → 拒（rc=${r2}）" '[ $r1 = 1 ] && grep -q "至少给一个开关" <<< "$o1" && [ $r2 = 1 ] && grep -q "MERGE_OWNER" <<< "$o2"'
F=$H/tests/fixtures/alloc_gate; A=$(ls $F | head -1); B=$(ls $F | sed -n 2p)
mk() { mkdir -p $T/sched/jobs/$1/out_1; cp $F/$2/host.log $F/$2/frames.tsv $T/sched/jobs/$1/out_1/; printf 'G=acnh\nCOMMIT=c0ffee1\nNOTE=%q\nENVS=%q\n' "$3" "$4" > $T/sched/jobs/$1.job; }
mk acnh_1_2 $A "A/B 42 A（缺省）" "S2A_AB=42:A"; mkdir -p $T/sched/jobs/acnh_2_2; printf 'G=acnh\nCOMMIT=c0ffee1\nNOTE=%q\nENVS=%q\n' "A/B 42 B（X=1）" "S2A_AB=42:B X=1" > $T/sched/jobs/acnh_2_2.job
o3=$(bash $H/tools/ab.sh report 42 --wait=0 2>&1); r3=$?
ck "B 局没结果 → 「未出结果」、退出非 0（rc=${r3}）" '[ $r3 != 0 ] && grep -q "^B .*未出结果" <<< "$o3"'
rm -rf $T/sched/jobs/acnh_2_2; mk acnh_2_2 $B "A/B 42 B（X=1）" "S2A_AB=42:B X=1"; o4=$(bash $H/tools/ab.sh report 42 2>&1); r4=$?
ck "两局都有结果 → 两行对比（读回 / 帧数 / 每帧分配 / GC 可玩段最长）、退出 0（rc=${r4}）" '[ $r4 = 0 ] && [ "$(grep -c "读回 [0-9.]* ms｜每帧分配 [0-9]* B｜GC 可玩段最长" <<< "$o4")" = 2 ] && grep -q "^A .*包 c0ffee1  S2A_AB=42:A" <<< "$o4" && grep -q "^B .*S2A_AB=42:B X=1" <<< "$o4"'
# 号带款名（同一秒连登两款不撞号）；两局要么都入队要么都不入：假调度第 1 次入队、第 2 次被上限挡 → 撤掉第 1 次那单、退出非 0
cat > $T/fsch <<'FS'
#!/bin/bash
n=$(cat "$S2A_SCHED_DIR/fsch_n" 2>/dev/null || echo 0); n=$((n + 1)); echo $n > "$S2A_SCHED_DIR/fsch_n"; echo "$*" >> "$S2A_SCHED_DIR/fsch_args"
if [ $n = 1 ]; then mkdir -p "$S2A_SCHED_DIR/queue"; echo "$*" > "$S2A_SCHED_DIR/queue/2_1_a.job"; echo "已入队 2_1_a.job；结果看 x"; exit 0; fi
echo "🔴 测试 已有 3 个真机作业在排队（上限 3）"; exit 1
FS
chmod +x $T/fsch; printf 'COMMIT=c0ffee1\n' > $T/sched/pkgs/acnh.env
o5=$(MERGE_OWNER=测试 S2A_AB_SCHED=$T/fsch bash $H/tools/ab.sh acnh X=1 2>&1); r5=$?
ck "B 被上限挡 → 撤掉已入队的 A、退出非 0（rc=${r5}）；号带款名（acnh-<时刻>-<进程号>）" '[ $r5 != 0 ] && [ ! -e $T/sched/queue/2_1_a.job ] && grep -q "已撤掉 A 局（2_1_a.job）" <<< "$o5" && grep -q "S2A_AB=acnh-[0-9]*-[0-9]*:A" $T/sched/fsch_args'
# GC 读数按整局最长取（10-23：frame_gate 措辞改「整局最长」后报表一度全成「未测」）：八方2 两局夹具（截首行 + MARK 后 61 秒），期望手算见 score_test：15.60 ms（帧 3471）/ 11.62 ms（帧 3728）
O2=$H/tests/fixtures/alloc_gate; rm -rf $T/sched/jobs/acnh_*; mk acnh_1_2 octopath2_1022230600_2 "A/B 43 A（缺省）" "S2A_AB=43:A"; mk acnh_2_2 octopath2_1022231746_2 "A/B 43 B（X=1）" "S2A_AB=43:B X=1"
o6=$(bash $H/tools/ab.sh report 43 2>&1)
ck "报表 GC 取到整局最长：两局各 15.60 ms（帧 3471）/ 11.62 ms（帧 3728）中的一个、不是未测" 'grep -q "GC 可玩段最长 15.60 ms（帧 3471）" <<< "$o6" && grep -q "GC 可玩段最长 11.62 ms（帧 3728）" <<< "$o6" && ! grep -q "GC 可玩段最长 未测" <<< "$o6"'

# 功耗列 + 噪声底（10-23 总指挥：A/A 动森两局差 0.07 W、塞尔达极差 0.19 W → A 局 ≥ 3.3 W 重款 0.2 W，否则轻款 0.1 W）：
#   手造窗口两端采样：A 系统负载 0→3 000 000、次数 0→1000 → 3.00 W；B 0→3 150 000 → 3.15 W、充电中 → 差 +0.15 W > 轻款 0.1 W → 超出噪声
pl() { python3 -c "import plistlib,sys; [plistlib.dump({'IORegistry': {'IsCharging': sys.argv[3] == '1', 'FullyCharged': False, 'PowerTelemetryData': {'SystemLoadAccumulatorCount': n, 'AccumulatedSystemLoad': v}}}, open(sys.argv[1] + '/' + f, 'wb')) for f, n, v in (('pwh.plist', 0, 0), ('pw1.plist', 1000, int(sys.argv[2])))]" "$@"; }
pl $T/sched/jobs/acnh_1_2/out_1 3000000 0; pl $T/sched/jobs/acnh_2_2/out_1 3150000 1; : > $T/nz0.tsv; o7=$(S2A_AB_NOISE_TSV=$T/nz0.tsv bash $H/tools/ab.sh report 43 2>&1)   # 空表：与仓库里实际登记了哪些款无关
ck "功耗列：A 3.00 W（未充电）、B 3.15 W（充电中）；acnh 表里没有 → 无噪声底、功耗不判" 'grep -q "^A .*｜功耗 3.00 W（未充电·" <<< "$o7" && grep -q "^B .*｜功耗 3.15 W（充电中·" <<< "$o7" && grep -q "功耗差 B−A +0.15 W；acnh 无噪声底.*功耗不判" <<< "$o7"'
#   按款噪声底（10-23 总指挥：同包 A/A ≥ 3 局极差）：手造表 acnh 0.10 W → 差 +0.15 W 超出；acnh 0.20 W → 噪声内
printf 'acnh\t0.10\t3\t单测\n' > $T/nz.tsv; o8=$(S2A_AB_NOISE_TSV=$T/nz.tsv bash $H/tools/ab.sh report 43 2>&1)
printf 'acnh\t0.20\t3\t单测\n' > $T/nz.tsv; o9=$(S2A_AB_NOISE_TSV=$T/nz.tsv bash $H/tools/ab.sh report 43 2>&1)
ck "按款噪声底：acnh 0.10 W → +0.15 W 超出噪声；0.20 W → 噪声内" 'grep -q "功耗差 B−A +0.15 W，噪声底 0.10 W（acnh：3 局 A/A 极差（单测））→ 超出噪声" <<< "$o8" && grep -q "噪声底 0.20 W（acnh：.*→ 噪声内" <<< "$o9"'

# 场景量级（10-23 塞尔达 A 局 DLC 介绍页当 MARK：每帧绘制 114 vs 正常局 2280）：给两局 frames.tsv 补 draw_n 列，A 114、B 2280 → 报「不可比」、不出功耗差
adddraw() { awk -F'\t' -v OFS='\t' -v d="$2" 'NR == 1 { print $0, "draw_n"; next } { print $0, d }' "$1/frames.tsv" > "$1/f2" && mv "$1/f2" "$1/frames.tsv"; }
adddraw $T/sched/jobs/acnh_1_2/out_1 114; adddraw $T/sched/jobs/acnh_2_2/out_1 2280; o10=$(S2A_AB_NOISE_TSV=$T/nz.tsv bash $H/tools/ab.sh report 43 2>&1)
ck "两局每帧绘制 114 / 2280（差 20 倍）→ 不可比、不出功耗差" 'grep -q "不可比：两局 MARK 后每帧绘制中位 A 114 / B 2280" <<< "$o10" && ! grep -q "^功耗差" <<< "$o10"'

[ $bad = 0 ] && echo "ab 单测全过" || { echo "ab 单测有不通"; echo "$o3"; echo "$o4"; exit 1; }
