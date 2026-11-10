#!/bin/bash
# 在两种 sed 上用临时文件完成同一替换。
sed_edit() { sed -i.s2a-bak "$1" "$2" && rm -f "$2.s2a-bak"; }
# 分配闸门 + 记分板五格单测（造局目录，期望值手算）：bash tests/score_test.sh
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0
# 看板 board.py 是维护方工具，迁仓时按规定留在 private-tools（11-09：公开仓里 import board 从首次公开快照起一直红）：
#   有 $S2A_PRIVATE_TOOLS/board.py 才测看板那几例，没有就逐条写明跳过（公开贡献者的环境里本来就没有看板）
BD=${S2A_PRIVATE_TOOLS:-}; [ -n "$BD" ] && [ -f "$BD/board.py" ] || BD=
bck() { if [ -n "$BD" ]; then ck "$@"; else echo "跳过 $1（看板 board.py 在 private-tools，公开仓不带；设 S2A_PRIVATE_TOOLS 才测）"; fi; }
# 噪声底表缺省给空表：既有用例测的是「近 3 局中位」等规则，不受「临界」档影响；临界档另有用例显式给表（10-30）
: > "$T/noise_empty.tsv"; export S2A_AB_NOISE_TSV=$T/noise_empty.tsv
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
# 造逐帧表：$1 目录 $2 帧数 $3 每帧间隔 us $4 每帧分配 B $5 从第几帧起 gen0 每帧 +1（0 = 不涨） $6 第几帧读回阻塞 40 ms（0 = 无）
mkf() { mkdir -p $1; awk -v n=$2 -v w=$3 -v al=$4 -v g=$5 -v rb=$6 'BEGIN{print "frame\twall_us\talloc_b\tgc0\tgc1\tgc2\trb_us\tshader_miss"; c=0; for(i=1;i<=n;i++){ if(g>0&&i>=g)c++; printf "%d\t%d\t%d\t%d\t0\t0\t%d\t0\n", i, w, al, c, (i==rb?40000:0)} }' > $1/frames.tsv; }
gate() { python3 $H/tools/frame_gate.py $1 --fps=$2 --mark=$3 | cut -f1; }
mkf $T/a 3000 33333 4000 0 0; ck "30 帧、每帧 4000 B、不回收 → 绿" '[ "$(gate $T/a 30 100)" = 绿 ]'
mkf $T/b 3000 33333 4200 0 0; ck "30 帧、每帧 4200 B > 4096 → 红（10-22 改判分配速率）" '[ "$(gate $T/b 30 100)" = 红 ] && python3 $H/tools/frame_gate.py $T/b --fps=30 --mark=100 | grep -q "每帧分配均值 4200 B > 4096 B"'
mkf $T/c 3000 16667 2100 0 0; ck "60 帧、每帧 2100 B > 2048 → 红" '[ "$(gate $T/c 60 100)" = 红 ]'
mkf $T/c2 3000 16667 2000 0 0; ck "60 帧、每帧 2000 B ≤ 2048 → 绿" '[ "$(gate $T/c2 60 100)" = 绿 ]'
mkf $T/d 3000 33333 100 500 0; ck "MARK 后 60 秒窗口内 gen0 涨（第 500 帧起）、分配低、没有停顿列 → 绿（gen0 只记录；停顿未测）" '[ "$(gate $T/d 30 100)" = 绿 ] && python3 $H/tools/frame_gate.py $T/d --fps=30 --mark=100 | grep -q "停顿未测.*只记录（不判）gen0 +[0-9]"'
mkf $T/d2 3000 33333 100 2500 0; ck "gen0 只在 60 秒窗口外涨（MARK 100 + 1800 帧之后，第 2500 帧起）→ 绿" '[ "$(gate $T/d2 30 100)" = 绿 ]'
mkf $T/e 3000 33333 100 50 0; ck "gen0 从第 50 帧起每帧涨（跨进窗口）→ 绿（只记录）" '[ "$(gate $T/e 30 100)" = 绿 ]'
# GC 停顿（frames.tsv 的 gc_pause_us = 本帧 GC 停顿合计）：可玩段（MARK 后）单帧最大 > 帧预算 25%（30 帧 8333 us / 60 帧 4167 us）→ 红
#   期望手算：30 帧预算 33333 us × 0.25 = 8333 us；60 帧 16667 × 0.25 = 4167 us。旧判据固定 2000 us：p1 / p2 / q2 三条旧代码判红（反证）
mkp() { mkdir -p $1; awk -v at=$2 -v us=$3 -v w=${4:-33333} 'BEGIN{print "frame\twall_us\talloc_b\tgc0\tgc1\tgc2\trb_us\tgc_pause_us"; for(i=1;i<=3000;i++) printf "%d\t%d\t100\t0\t0\t0\t0\t%d\n", i, w, (i==at?us:0)}' > $1/frames.tsv; }
mkp $T/p1 500 3000; ck "30 帧、窗口内一帧 GC 停顿 3 ms ≤ 8.3 ms → 绿（旧固定 2 ms 判红）" '[ "$(gate $T/p1 30 100)" = 绿 ]'
mkp $T/p2 500 8000; ck "30 帧、停顿 8.0 ms ≤ 8.3 ms → 绿" '[ "$(gate $T/p2 30 100)" = 绿 ]'
mkp $T/p4 500 8500; ck "30 帧、停顿 8.5 ms > 8.3 ms → 红" '[ "$(gate $T/p4 30 100)" = 红 ] && python3 $H/tools/frame_gate.py $T/p4 --fps=30 --mark=100 | grep -q "GC 停顿可玩段最长 8.50 ms > 8.3 ms（帧预算 25%，帧 500）"'
mkp $T/q2 500 4000 16667; ck "60 帧、停顿 4.0 ms ≤ 4.2 ms → 绿" '[ "$(gate $T/q2 60 100)" = 绿 ]'
mkp $T/q4 500 4300 16667; ck "60 帧、停顿 4.3 ms > 4.2 ms → 红" '[ "$(gate $T/q4 60 100)" = 红 ] && python3 $H/tools/frame_gate.py $T/q4 --fps=60 --mark=100 | grep -q "GC 停顿可玩段最长 4.30 ms > 4.2 ms"'
# 10-26 维护者改「只判可玩段」（维护者：玩的时候不卡）：MARK 前（加载段）的停顿单列一行、只报不判，取代 10-23「整局最长」
mkp $T/p3 50 9000; ck "9 ms gen0 停顿在 MARK 前 → 绿、加载段单列（10-23 整局判据 红）" '[ "$(gate $T/p3 30 100)" = 绿 ] && python3 $H/tools/frame_gate.py $T/p3 --fps=30 --mark=100 | grep -q "加载段（MARK 前，只报不判）最长 9.00 ms（帧 50）"'
# 巫师3 两局的形状（60 帧、上限 4.2 ms）：175521 加载段 51 ms、可玩段 0 次 → 绿；172400 可玩段 77 ms → 红
mkp $T/w1 50 51350 16667; ck "60 帧、加载段 51.35 ms、可玩段 0 次 → 绿" '[ "$(gate $T/w1 60 100)" = 绿 ] && python3 $H/tools/frame_gate.py $T/w1 --fps=60 --mark=100 | grep -q "可玩段（MARK 后）最长 0.00 ms（帧 -，.*加载段（MARK 前，只报不判）最长 51.35 ms（帧 50）"'
mkp $T/w2 500 77270 16667; ck "60 帧、可玩段 77.27 ms → 红" '[ "$(gate $T/w2 60 100)" = 红 ] && python3 $H/tools/frame_gate.py $T/w2 --fps=60 --mark=100 | grep -q "GC 停顿可玩段最长 77.27 ms > 4.2 ms（帧预算 25%，帧 500）"'
# 看板 GC 停顿一行（board.gc_line）：同包两局取最大。局 a：第 50 帧 9 ms gen0；局 b：第 70 帧 40 ms gen2、第 80 帧 12 ms gen1（帧表没有 draw_n → gen2 单列）
mkdir -p $T/gl/a/out $T/gl/b/out; mkp $T/gl/a/out 50 9000; mkp $T/gl/b/out 70 40000
awk 'NR>1 && $1>=70{$6=1} NR>1 && $1==80{$8=12000} NR>1 && $1>=80{$5=1}1' OFS='\t' $T/gl/b/out/frames.tsv > $T/gl/f && mv $T/gl/f $T/gl/b/out/frames.tsv
glo=$(python3 -c "import sys; sys.path.insert(0, '$BD'); import board; r = lambda d: ['', 'acnh', 'p'] + ['']*7 + [d]; print(board.gc_line([r('$T/gl/a/out'), r('$T/gl/b/out')]))" 2>&1)
bck "看板 GC 行：整局最长 12.00 ms（帧 80，b）、读盘中 gen2 最长 40.00 ms（帧 70，b）、同包 2 局（${glo}）" '[ "$glo" = "整局最长 12.00 ms（帧 80，b）；读盘中 gen2（不判）最长 40.00 ms（帧 70，b）（同包 2 局）" ]'
# gen2 游玩中照判（10-23 维护者）：帧号 > MARK，或前后 30 帧 draw_n 中位 ≥ MARK 后 draw_n 中位的 1/4。造 3000 帧、MARK 100、MARK 后 draw_n 400（门槛 100）
mkd() { mkdir -p $1; awk -v at=$2 -v dlo=$3 'BEGIN{print "frame\twall_us\talloc_b\tgc0\tgc1\tgc2\trb_us\tdraw_n\tgc_pause_us"; for(i=1;i<=3000;i++) printf "%d\t33333\t100\t0\t0\t%d\t0\t%d\t%d\n", i, (i>=at?1:0), (i<=100?dlo:400), (i==at?40000:0)}' > $1/frames.tsv; }
mkd $T/d1 50 20; ck "MARK 前 gen2、前后绘制中位 20 < 门槛 100（读盘）→ 单列不判、绿" '[ "$(gate $T/d1 30 100)" = 绿 ]'
mkd $T/d2 50 120; ck "MARK 前 gen2、前后绘制中位 120（游玩画面）→ 加载段只报、绿（10-26 起只判 MARK 后）" '[ "$(gate $T/d2 30 100)" = 绿 ] && python3 $H/tools/frame_gate.py $T/d2 --fps=30 --mark=100 | grep -q "加载段（MARK 前，只报不判）最长 40.00 ms（帧 50）"'
mkd $T/d3 900 0; ck "MARK 后 gen2 → 判、红" '[ "$(gate $T/d3 30 100)" = 红 ]'
mkp $T/p5 2900 9000; ck "9 ms 停顿在窗口之后（MARK 100 + 1800 帧 = 第 1900 帧止，停顿在第 2900 帧）→ 红" '[ "$(gate $T/p5 30 100)" = 红 ]'
mkp $T/g2 50 75000; awk 'NR>1 && $1>=50{$6=1}1' OFS='\t' $T/g2/frames.tsv > $T/g2/f && mv $T/g2/f $T/g2/frames.tsv
ck "75 ms 停顿在 MARK 前（gen2）→ 绿、加载段单列 75.00 ms（帧 50）" '[ "$(gate $T/g2 30 100)" = 绿 ] && python3 $H/tools/frame_gate.py $T/g2 --fps=30 --mark=100 | grep -q "加载段（MARK 前，只报不判）最长 75.00 ms（帧 50）"'
awk 'NR>1 && $1==60{$8=30000} NR>1 && $1>=60{$5=1}1' OFS='\t' $T/g2/frames.tsv > $T/g2/f && mv $T/g2/f $T/g2/frames.tsv
ck "同局再加第 60 帧 30 ms gen1（仍在 MARK 前）→ 绿（10-23 整局判据 红）" '[ "$(gate $T/g2 30 100)" = 绿 ]'
# 第 0 帧（首行 wall_us = 0）是启动以来的累计：首行 50 ms 停顿 + 2.4 亿 B 分配不算（整局停顿判据也不算它）→ 绿（旧代码两条都判红）
mkp $T/z 0 0; awk 'NR==2{$2=0;$3=243054000;$8=50974}1' OFS='\t' $T/z/frames.tsv > $T/z/f && mv $T/z/f $T/z/frames.tsv
ck "第 0 帧带启动累计（停顿 51 ms、分配 243 MB）→ 绿" '[ "$(python3 $H/tools/frame_gate.py $T/z --fps=30 --mark=100 | cut -f1)" = 绿 ]'
# 没有 MARK = 没有游玩窗口 → 未测（10-25 交付线审：原按整局算，读盘段分配进了窗口，动森直连局没到 MARK 判了红）
ck "无 MARK（host.log 没有 MARK 行、不给 --mark）→ 未测" '[ "$(python3 $H/tools/frame_gate.py $T/z --fps=30 | cut -f1)" = 未测 ] && python3 $H/tools/frame_gate.py $T/z --fps=30 | grep -q "没有 MARK"'
# 10-22 动森两包六局重判（帧率能耗线查实：00d56c668 掉红是压线——每次 gen0 之间累计约 15–16 MB，到 MARK 时都累计到 15.2–15.6 MB，只看落在阈值哪一边）：
#   新判据两包都应绿（MARK 后每帧均值 237–292 B）；旧判据 00d56c668 两局红（gen0 +1）
for d in $H/tests/fixtures/alloc_gate/acnh_*; do o=$(python3 $H/tools/frame_gate.py $d | cut -f1); ck "动森重判 $(basename $d) → 绿（${o}）" '[ "$o" = 绿 ]'; done
# 10-22 夜帧率能耗线真局（截首行 + MARK 起 61 秒；帧率按 host.log 帧节拍，三款都是 30 帧 → 停顿上限 8.3 ms）。期望手算（awk 扫 MARK 后满 60 秒的 gc_pause_us）：
#   动森 3 局窗口内停顿全 0 → 绿；巫师3 窗口内全 0 → 绿（夹具只截了 MARK 后，MARK 前那几次 21.6 / 24.0 / 13.1 ms 不在夹具里；10-26 起只判 MARK 后，真局也绿）；
#   八方2 两局窗口内最长 15.60 ms（帧 3471）/ 11.62 ms（帧 3728）> 8.3 → 红，且红因含停顿这一条（另有分配均值 6267 / 6255 B 超、读回超）
for d in $H/tests/fixtures/alloc_gate/witcher3_*; do o=$(python3 $H/tools/frame_gate.py $d | cut -f1); ck "巫师3 $(basename $d) → 绿（${o}）" '[ "$o" = 绿 ]'; done
for d in $H/tests/fixtures/alloc_gate/octopath2_*; do o=$(python3 $H/tools/frame_gate.py $d); ck "八方2 $(basename $d) → 红且含停顿超（${o%%（*}）" '[ "${o%%	*}" = 红 ] && echo "$o" | grep -q "GC 停顿可玩段最长 1[15]\.[0-9]* ms > 8.3 ms"'; done
awk 'NR==1||$1<=100{print; next}{ $4=51; print }' OFS='\t' $T/e/frames.tsv > $T/e2.tsv; mkdir -p $T/e2; mv $T/e2.tsv $T/e2/frames.tsv
ck "gen0 只在 MARK 前涨、窗口内不变 → 绿" '[ "$(gate $T/e2 30 100)" = 绿 ]'
mkf $T/f 3000 33333 100 0 500; ck "单帧读回 40 ms > 33.3 ms 预算 → 红" '[ "$(gate $T/f 30 100)" = 红 ]'
mkf $T/g 3000 33333 100 0 50; ck "读回尖峰在 MARK 前 → 绿" '[ "$(gate $T/g 30 100)" = 绿 ]'
mkdir -p $T/h; printf 'frame\twall_us\n1\t33333\n2\t33333\n' > $T/h/frames.tsv; ck "缺分配列 → 未测" '[ "$(gate $T/h 30 1)" = 未测 ]'
# 五格：造一局 MARK 帧 100，窗口 60 秒 30 帧/秒（1800 帧），有声、满屏判据开、无报红
L=$T/run; mkf $L 1900 33333 100 0 0
printf 'S2A 就绪\n[gal] 帧节拍：交换间隔 2，每帧 33.3 ms（30.0 帧/秒）\n[画] 满屏判据 已开\nS2A 标记 MARK：帧 100\n[声] 稳态窗口：输出峰值 0.42\n' > $L/host.log; : > $L/run.log; echo 清 > $L/cold_start.txt
sc() { python3 $H/tools/score_cells.py $1 --game=acnh --commit=abc --board=$T/board.tsv ${2:-} 2>/dev/null; }
R=$(sc $L); IFS=$'\t' read -r _ g c play pic fps pow first alloc _ <<< "$R"
ck "好局：能玩 绿" '[ "$play" = 绿 ]'
ck "好局：画面 未测（没有真值表）" '[ "$pic" = 未测 ]'
ck "好局：帧率 绿（1800 帧 × 33.333 ms = 60 秒，游戏要交换间隔 2 = 30 帧/秒）" '[ "$fps" = 绿 ]'
cp $L/host.log $L/hf; sed_edit 's/交换间隔 2，每帧 33.3 ms（30.0 帧/交换间隔 1，每帧 16.7 ms（60.0 帧/' $L/host.log
R=$(sc $L --diag=1); IFS=$'\t' read -r _ _ _ _ _ fps _ <<< "$R"; ck "游戏要交换间隔 1（60 帧/秒）、实际 30 帧/秒 → 帧率 红" '[ "$fps" = 红 ]'
# 10-26 维护者：上屏间隔分不出「游戏自限 30」和「我方慢到每帧 2 vsync」，有 disp_us 列、2 vsync 占 100% 也仍按声明的 60 判（宁红不假绿；撤回 3848fe787 的反证）
mkdir -p $T/v2; cp $L/host.log $L/run.log $L/cold_start.txt $T/v2/; awk 'BEGIN{print "frame\twall_us\tdisp_us\talloc_b\tgc0\tgc1\tgc2\trb_us\tshader_miss"; for(i=1;i<=1900;i++) printf "%d\t33333\t33333\t100\t0\t0\t0\t0\t0\n", i}' > $T/v2/frames.tsv
R=$(sc $T/v2 --diag=1); IFS=$'\t' read -r _ _ _ _ _ fps _ <<< "$R"; ck "交换间隔 1、上屏 2 vsync 占 100%（disp_us）→ 仍要 60、帧率 红" '[ "$(python3 $H/tools/game_fps.py $T/v2 | cut -f1)" = 60 ] && [ "$fps" = 红 ]'
# 帧率真值表（Ryujinx 关垂直同步实测）：程序号在表里 → 按表；不在 → 按声明。夹具表 S2A_FPS_TRUTH_TSV，不碰仓库那张
export S2A_FPS_TRUTH_TSV=$T/fps_truth.tsv
printf '程序号\t款\t目标帧率\t实测中位帧率\tGPU队列中位%%\t样本数\t证据\t日期\n00aa00aa00aa0001\tt\t30\t30.0\t0\t20\tfps_truth/t.log\t10-26 00:00\n' > $S2A_FPS_TRUTH_TSV
mkdir -p $T/v3; cp $T/v2/* $T/v3/; echo '[s2a] 图形模式：直连（依据 缺省；程序号 00aa00aa00aa0001）' >> $T/v3/host.log
R=$(sc $T/v3 --diag=1); IFS=$'\t' read -r _ _ _ _ _ fps _ <<< "$R"; ck "程序号在真值表（实测 30）、声明间隔 1、实际 30 帧 → 要 30、帧率 绿" '[ "$(python3 $H/tools/game_fps.py $T/v3 | cut -f1)" = 30 ] && python3 $H/tools/game_fps.py $T/v3 | grep -q "帧率真值表" && [ "$fps" = 绿 ]'
sed_edit 's/00aa00aa00aa0001）/00aa00aa00aa0002）/' $T/v3/host.log; ck "程序号不在真值表 → 按声明 60" '[ "$(python3 $H/tools/game_fps.py $T/v3 | cut -f1)" = 60 ]'
# 帧率表优先于真值表（10-26 维护者定，异度3 形态）：真值表 30 + 包里带 60 帧表放开出图间隔 → 按 60 判（不放过「表开了却只跑 30」）；
#   旧代码反证：先查真值表那版按 30 判、帧率 绿，本条红
mkdir -p $T/v4; cp $T/v3/* $T/v4/; sed_edit 's/00aa00aa00aa0002）/00aa00aa00aa0001）/' $T/v4/host.log
echo '[s2a] 帧率表 /x/S2Arm.app/fps.tsv：60 帧开；出图间隔放开（每个显示节拍一帧），数据写入 1 处' >> $T/v4/host.log   # 宿主现行格式（runtime/src/fps.c）
R=$(sc $T/v4 --diag=1); IFS=$'\t' read -r _ _ _ _ _ fps _ <<< "$R"; ck "真值表 30 + 包带 60 帧表 → 要 60（表优先）、实际 30 帧 → 帧率 红" '[ "$(python3 $H/tools/game_fps.py $T/v4 | cut -f1)" = 60 ] && python3 $H/tools/game_fps.py $T/v4 | grep -q "帧率表 fps.tsv" && [ "$fps" = 红 ]'
unset S2A_FPS_TRUTH_TSV
# fps_truth.py 判法（期望手算：丢前 2 行后取 fifo < 50 的样本中位）：异度3 形态 30 帧 / 队列 0% → 30；马车8 形态 177 帧 → 60；
#   Ryujinx 自己跑满（30 帧、队列 95%）→ 判不了、不写表（不把「Ryujinx 慢」当成「游戏限 30」）
fl() { awk -v g=$2 -v f=$3 'BEGIN{print "[fps] game 0.0 fifo 0 frametime x"; print "[fps] game 12.0 fifo 100 frametime x"; for(i=0;i<10;i++) printf "[fps] game %s fifo %s frametime x\n", g, f}' > $1; }
fl $T/f30.txt 30.0 0; fl $T/f177.txt 177.4 9; fl $T/fbusy.txt 30.0 95
ck "fps_truth：30 帧 / 队列 0% → 30" '[ "$(python3 $H/tools/fps_truth.py t 00aa00aa00aa0001 $T/f30.txt | cut -f3)" = 30 ]'
ck "fps_truth：177 帧 → 60" '[ "$(python3 $H/tools/fps_truth.py t 00aa00aa00aa0001 $T/f177.txt | cut -f3)" = 60 ]'
ck "fps_truth：30 帧但队列 95%（Ryujinx 跑满）→ 判不了、退出 1" '! python3 $H/tools/fps_truth.py t 00aa00aa00aa0001 $T/fbusy.txt > /dev/null'
printf '[gal] 帧节拍：交换间隔 2，每帧 33.3 ms（30.0 帧/秒）\n' >> $L/host.log; R=$(sc $L --diag=1); IFS=$'\t' read -r _ _ _ _ _ fps _ <<< "$R"; ck "帧节拍改过：取最后一行（又回 30 帧/秒）→ 帧率 绿" '[ "$fps" = 绿 ]'
sed_edit '/帧节拍/d' $L/host.log; R=$(sc $L --diag=1 2>&1; python3 $H/tools/score_cells.py $L --game=acnh --commit=abc --diag=1 2>&1 >/dev/null); IFS=$'\t' read -r _ _ _ _ _ fps _ <<< "$R"
ck "host.log 没有帧节拍行（包早于 fbf80e3）→ 局无效：六格「—」、写明「没有「帧节拍」行」（不按 60 判出假红）" '[ "$fps" = — ] && grep -q "【局无效】包里没有「帧节拍」行" <<< "$R"'
cp $L/hf $L/host.log; echo '[gal] 帧率上限 S2A_FPS=30：交换间隔下限 2（vsync 60 Hz）' >> $L/host.log; R=$(sc $L --diag=1); IFS=$'\t' read -r _ _ _ _ _ fps _ <<< "$R"
ck "host.log 有「帧率上限 S2A_FPS=30」→ 局无效「帧率被测试封顶」" '[ "$fps" = — ] && grep -q "【局无效】帧率被测试封顶（S2A_FPS=30）" <<< "$R"'
# 未满屏读数不作数（10-26 维护者「满屏是目标，不是可选项」）：屏幕 2868x1320 → 屏比 2.173。好局（30 帧、帧率本来绿）加上出图层 / 屏幕行
SH='[s2a] iOS 壳：朝向 横屏（3），视图 956x440 点，屏幕 2868x1320 像素，屏幕宽（1080 高对应）2346'
cp $L/hf $L/host.log; printf '%s\n[s2a] 直连：出图层已挂到根视图 2346x1320 像素（宽高比 1.777，居中；宽屏第二层关）\n' "$SH" >> $L/host.log; R=$(sc $L --diag=1); IFS=$'\t' read -r _ _ _ _ _ fps pw _ <<< "$R"
ck "直连出图层 1.777 ≠ 屏比 2.173（差 18%）→ 帧率 / 能耗 未测、读数标「未满屏，读数不作数」" '[ "$fps" = 未测 ] && [ "$pw" = 未测 ] && grep -q "【未满屏，读数不作数：局内红：直连出图层宽高比 1.777，屏比 2.173】" <<< "$R"'
cp $L/hf $L/host.log; printf '%s\n[s2a] 直连：出图层已挂到根视图 2868x1320 像素（宽高比 2.173，居中；宽屏第二层开）\n' "$SH" >> $L/host.log; R=$(sc $L --diag=1); IFS=$'\t' read -r _ _ _ _ _ fps _ <<< "$R"
ck "直连出图层 2.173 = 屏比 → 照常判（帧率 绿）" '[ "$fps" = 绿 ] && ! grep -q 未满屏 <<< "$R"'
cp $L/hf $L/host.log; printf '%s\n[s2a] 直连：出图层已挂到根视图 2346x1320 像素（宽高比 1.777，居中；宽屏第二层关）\n[s2a] 直连：出图层已挂到根视图 2868x1320 像素（宽高比 2.173，居中；宽屏第二层开）\n' "$SH" >> $L/host.log; R=$(sc $L --diag=1); IFS=$'\t' read -r _ _ _ _ _ fps _ <<< "$R"
ck "出图层重挂过、最后一次 = 屏比 → 照常判" '[ "$fps" = 绿 ]'
cp $L/hf $L/host.log; echo '[gal] 【红】出图未满屏（几何，第 500 次出图起，累计第 1 次）：画面 1920x1080 上屏只占 2346 / 2868 像素宽（左右留边）' >> $L/host.log; R=$(sc $L --diag=1); IFS=$'\t' read -r _ _ _ _ _ fps _ <<< "$R"
ck "局内（MARK 帧 100 之后，第 500 次出图）报过「出图未满屏」→ 帧率 未测、读数标注" '[ "$fps" = 未测 ] && grep -q "【未满屏，读数不作数：局内红：出图报过「出图未满屏」（局内 1 条）" <<< "$R"'
# 界面页一层（维护者 11-02：菜单 / 暂停等页面满屏是另一层问题，不是不能开满屏的阻塞项）：同一行红出在 MARK 之前（第 5 次出图）、第 9 次恢复 → 不算未满屏，帧率照常判（没恢复、延续进局内的算局内，见 quality_check_test ⑲e）
cp $L/hf $L/host.log; printf '%s\n' '[gal] 【红】出图未满屏（几何，第 5 次出图起，累计第 1 次）：画面 1920x1080 上屏只占 2346 / 2868 像素宽（左右留边）' '[gal] 出图恢复满屏（几何，第 9 次出图起，累计第 1 次）' >> $L/host.log; R=$(sc $L --diag=1); IFS=$'\t' read -r _ _ _ _ _ fps _ <<< "$R"
ck "MARK 前（第 5 次出图）报过「出图未满屏」= 界面页 → 照常判（帧率 绿）" '[ "$fps" = 绿 ]'
cp $L/hf $L/host.log; echo '[07:40:00] 【黄】host.log 没拉回：用控制台流顶上（30 行；C# 侧行缺）' > $L/run.log; R=$(sc $L --diag=1); IFS=$'\t' read -r _ _ _ _ _ fps _ <<< "$R"
ck "host.log 由控制台流顶上 → 局无效「只有控制台流」" '[ "$fps" = — ] && grep -q "【局无效】host.log 没拉回、只有控制台流" <<< "$R"'
: > $L/run.log
ck "好局：能耗 未测（没有功率读数）" '[ "$pow" = 未测 ]'
# 能耗绿要同局帧率保持（10-22 维护者「偏热 + 保持帧率、冷机 + 保持帧率都算过关」）：整机 3.00 W（≤ 3.7）——帧率绿 → 能耗绿；游戏要 60 帧、实际 30（帧率红）→ 能耗红、读数注「帧率未保持」
PF=$T/pf; cp -R $L $PF; cp $L/hf $PF/host.log
python3 -c "import plistlib,sys; [plistlib.dump({'IORegistry': {'IsCharging': False, 'PowerTelemetryData': {'SystemLoadAccumulatorCount': n, 'AccumulatedSystemLoad': a}}}, open(f'{sys.argv[1]}/{x}', 'wb')) for x, n, a in (('pwh.plist', 0, 0), ('pw1.plist', 100, 300000))]" $PF
R=$(sc $PF --diag=1); IFS=$'\t' read -r _ _ _ _ _ fps pow _ <<< "$R"; ck "3.00 W、帧率绿 → 能耗 绿（帧率 ${fps}）" '[ "$fps" = 绿 ] && [ "$pow" = 绿 ]'
sed_edit 's/交换间隔 2，每帧 33.3 ms（30.0 帧/交换间隔 1，每帧 16.7 ms（60.0 帧/' $PF/host.log
R=$(sc $PF --diag=1); IFS=$'\t' read -r _ _ _ _ _ fps pow _ <<< "$R"; ck "3.00 W 达标、但游戏要 60 帧只出 30（帧率红）→ 能耗 红、读数注「帧率未保持」" '[ "$fps" = 红 ] && [ "$pow" = 红 ] && grep -q "3.00 W（[^）]*，帧率未保持）" <<< "$R"'
o=$(python3 -c "import sys; sys.path.insert(0, '$H/tools'); from score_cells import vote
rw = lambda f, w: ['t', 'acnh', 'x', '绿', '未测', f, '绿' if f == '绿' else '红', '红', '红', f'33.3 ms / 慢帧 0.00% / {w} W', '', '', '', '']
print(vote([rw('红', '3.00')])['能耗'], vote([rw('绿', '3.10'), rw('红', '3.00'), rw('红', '2.90')])['能耗'], vote([rw('绿', '3.10'), rw('绿', '3.20'), rw('红', '2.90')])['能耗'])")
ck "投票：1 局 3.00 W 帧率红 → 红；3 局里 2 局帧率红 → 红（帧率未保持 2 局）；3 局里 1 局帧率红 → 中位按 3.10 / 3.20 / 不达标 → 3.20 绿（${o}）" 'grep -q "^(.红., 1, .中位 3.00 W（3.00–3.00，1 局，暂定，帧率未保持 1 局）；各状态：[^)]*.) (.红., 3, .中位 3.00 W（2.90–3.10，3 局，帧率未保持 2 局）；各状态：[^)]*.) (.绿., 3, .中位 3.10 W（2.90–3.20，3 局，帧率未保持 1 局）；各状态：[^)]*.)$" <<< "$o"'
o=$(python3 -c "import sys; sys.path.insert(0, '$H/tools'); from score_cells import vote
rf = lambda f: ['t', 'acnh', 'x', '绿', '未测', '绿', '绿', f, '绿', '读数', '', '', '', '']
print(vote([rf('红'), rf('绿'), rf('红'), rf('红')])['首局'][0], vote([rf('红')])['首局'][0], vote([rf('未测')])['首局'][0], vote([])['首局'][0])")
ck "首局投票（10-24 维护者 任一局过即绿）：4 局里 1 局绿 → 绿；单局红 → 红；只有未测 / 没有局 → 未测（${o}）" '[ "$o" = "绿 红 未测 未测" ]'
ck "好局：首局 绿（无 > 100 ms 帧、现翻 0）" '[ "$first" = 绿 ]'
awk 'NR==1{print;next} $1==500{$8=2} {print}' OFS='\t' $L/frames.tsv > $L/fm && cp $L/frames.tsv $L/f0 && mv $L/fm $L/frames.tsv
R=$(sc $L --diag=1); IFS=$'\t' read -r _ _ _ _ _ _ _ first _ <<< "$R"; ck "冷局现翻着色器 2 个 → 首局 红" '[ "$first" = 红 ]'
awk 'NR==1{print $0"\tpso_n";next} {print $0"\t"($1==300?1:0)}' OFS='\t' $L/f0 > $L/frames.tsv; R=$(sc $L --diag=1); IFS=$'\t' read -r _ _ _ _ _ _ _ first _ <<< "$R"; ck "冷局现建管线 1 支 → 首局 红" '[ "$first" = 红 ]'
cut -f1-7 $L/f0 > $L/frames.tsv; R=$(sc $L --diag=1); IFS=$'\t' read -r _ _ _ _ _ _ _ first _ <<< "$R"; ck "没有 shader_miss 列 → 首局 未测" '[ "$first" = 未测 ]'
mv $L/f0 $L/frames.tsv
# 首遇特化慢（10-21 画面·着色器线：「【首遇】管线特化慢：x ms」归首局格）：冷局有 2 行 → 首局 红、读数「首遇特化慢 2」；没有 → 绿、读数 0
cp $L/host.log $L/h0; printf '【首遇】管线特化慢：3.2 ms（第 373 次特化，累计慢 1 次）\n【首遇】管线特化慢：1.4 ms（第 380 次特化，累计慢 2 次）\n' >> $L/host.log
R=$(sc $L --diag=1); IFS=$'\t' read -r _ _ _ play _ _ _ first _ rdg _ <<< "$R"; ck "冷局首遇特化慢 2 行 → 首局 红、能玩不受影响（${play}）、读数「首遇特化慢 2」" '[ "$first" = 红 ] && [ "$play" = 绿 ] && grep -q "首遇特化慢 2 /" <<< "$rdg"'
mv $L/h0 $L/host.log; R=$(sc $L --diag=1); IFS=$'\t' read -r _ _ _ _ _ _ _ first _ rdg _ <<< "$R"; ck "没有首遇行 → 首局 绿、读数「首遇特化慢 0」" '[ "$first" = 绿 ] && grep -q "首遇特化慢 0 /" <<< "$rdg"'
# >100 ms 帧按渲染线程 wall_us，不按 vsync 量化后的 disp_us（10-20 动森开局一帧 104–112 ms，disp 有时 83+83、有时 100+100）
#   （10-22 起首局只计我方开销造成的大帧：这帧带宏耗时 95 ms ≥ 104 × 70%，算我方）
cp $L/frames.tsv $L/f0; awk 'NR==1{print $0"\tdisp_us\tmacro_us";next} {d=33336} $1==175||$1==176{d=83340} {m=0; if($1==174){$2=104000; m=95000}; print $0"\t"d"\t"m}' OFS='\t' $L/f0 > $L/frames.tsv
R=$(sc $L --diag=1); IFS=$'\t' read -r _ _ _ _ _ _ _ first _ <<< "$R"; ck "wall 一帧 104 ms（宏 95 ms，我方）、disp 量化成 83+83 → 首局 红" '[ "$first" = 红 ]'
awk 'NR==1{print $0"\tdisp_us";next} {d=33336} $1==175||$1==176{d=100009} {print $0"\t"d}' OFS='\t' $L/f0 > $L/frames.tsv
R=$(sc $L --diag=1); IFS=$'\t' read -r _ _ _ _ _ _ _ first _ <<< "$R"; ck "wall 都正常、disp 量化成 100+100 → 首局 绿" '[ "$first" = 绿 ]'
# >100 ms 帧按归因（10-22 维护者）：我方 = 当帧宏耗时 ≥ 帧时 70% 或有当场翻译 / 建管线 / 现翻着色器，全程都算；其余是游戏自己加载，单列读数、不计首局格。
#   夹具 = 10-22 七款冷启正式局全部 19 个 >100 ms 帧的真实读数（tests/fixtures/score_first/big19.tsv），放到第 50–68 帧（MARK 100 之前）。
#   手算：宏 ≥70% 的 9 帧（塞尔达 607、怪猎 1141 1155 1775、马车8 1581、八方2 1968、巫师3 1754，怪猎 1125 / 巫师3 1753 另有建管线）+ 八方2 第 5 帧（建管线 2）= 我方 10；
#   暗黑3 753、怪猎 1154、八方2 151 179 1919、丝之歌 21 797 1322 3050 = 游戏加载 9。旧口径（按全部大帧）：19 帧都计
big19() {   # big19 <只取游戏加载帧 0/1>：f0 加 macro_us / xlate_n / pso_n 三列，第 50 帧起依次换成夹具行
  python3 - $L/f0 $H/tests/fixtures/score_first/big19.tsv $1 > $L/frames.tsv <<'PY'
import sys
f0, fx, game_only = sys.argv[1], sys.argv[2], sys.argv[3] == '1'
B = [l.rstrip('\n').split('\t') for l in open(fx) if not l.startswith(('#', '来源'))]
B = [b for b in B if not game_only or not (int(b[3]) >= 0.7 * int(b[2]) or int(b[4]) or int(b[5]) or int(b[6]))]
L = [l.rstrip('\n').split('\t') for l in open(f0)]; h = L[0]; print('\t'.join(h + ['macro_us', 'xlate_n', 'pso_n']))
for r in L[1:]:
    i = int(r[0]) - 50; x = ['0', '0', '0']
    if 0 <= i < len(B): b = B[i]; r[h.index('wall_us')] = b[2]; r[h.index('shader_miss')] = b[6]; x = [b[3], b[4], b[5]]
    print('\t'.join(r + x))
PY
}
big19 0; R=$(sc $L --diag=1); IFS=$'\t' read -r _ _ _ _ _ _ _ first _ rdg _ <<< "$R"
ck "19 个真实大帧：首局 红、读数「>100ms 19（我方 10、游戏加载停顿 9）」" '[ "$first" = 红 ] && grep -q ">100ms 19（我方 10、游戏加载停顿 9）" <<< "$rdg"'
big19 1; R=$(sc $L --diag=1); IFS=$'\t' read -r _ _ _ _ _ _ _ first _ rdg _ <<< "$R"
ck "只有 9 个游戏加载帧（我方 0）→ 首局 绿（10-24 起不要热局对照，按归因判）、读数「>100ms 9（我方 0、游戏加载停顿 9）」" '[ "$first" = 绿 ] && grep -q ">100ms 9（我方 0、游戏加载停顿 9）" <<< "$rdg"'
mv $L/f0 $L/frames.tsv
ck "好局：分配 绿" '[ "$alloc" = 绿 ]'
ck "记分板写了表头 + 1 行" '[ "$(wc -l < $T/board.tsv)" -eq 2 ] && head -1 $T/board.tsv | grep -q "^时间	款	包提交	能玩"'
printf '游戏\t检查点\t总判\nacnh\t岛\t过\nacnh\t屋\t过\n' > $T/truth.tsv
R=$(sc $L "--truth=$T/truth.tsv"); IFS=$'\t' read -r _ _ _ play pic fps pow first _ <<< "$R"; ck "真值全过 + 满屏开 → 画面 绿；不带冷启的局也判首局（10-24 起不分冷热）→ 首局 绿" '[ "$pic" = 绿 ] && [ "$first" = 绿 ]'
printf '【红】未实现：hid/1001\n' >> $L/host.log; R=$(sc $L); IFS=$'\t' read -r _ _ _ play _ <<< "$R"; ck "宿主报红 1 行 → 能玩 红" '[ "$play" = 红 ]'
sed_edit '/未实现/d; /声/d' $L/host.log; R=$(sc $L); IFS=$'\t' read -r _ _ _ play _ <<< "$R"; ck "没有声音读数 → 能玩 未测" '[ "$play" = 未测 ]'
awk 'NR==1{print;next} $1>100&&$1<=1000{$2=36000} {print}' OFS='\t' $L/frames.tsv > $L/f2 && mv $L/f2 $L/frames.tsv
R=$(sc $L); IFS=$'\t' read -r _ _ _ _ _ fps _ <<< "$R"; ck "窗口 900 帧 36 ms（平均 < 29.7 帧/秒，慢帧 0）→ 帧率 红" '[ "$fps" = 红 ]'
printf '自检：窗口 整块（0x7000000000 +65536 MB）｜可用内存 6142 MB（需 ≥ 6144 MB）\n' >> $L/host.log; R=$(sc $L --diag=1); ck "读数列带起局自检（窗口整块、内存 6142 MB）" 'grep -q "自检 窗口整块 内存 6142 MB" <<< "$R"'
awk 'NR==1{print $0"\tdisp_us";next}{ $2=36000; print $0"\t33333" }' OFS='\t' $L/frames.tsv > $L/f3 && mv $L/f3 $L/frames.tsv
R=$(sc $L --diag=1); IFS=$'\t' read -r _ _ _ _ _ fps _ <<< "$R"; ck "有 disp_us 就按它判帧率（wall_us 36 ms 抖、disp_us 33.3 ms → 绿）" '[ "$fps" = 绿 ]'
R=$(sc $L --diag=1); ck "诊断局不写记分板" '[ "$(wc -l < $T/board.tsv)" -eq 6 ]'
cp $L/hf $L/host.log
# 测试未到位：自动玩家导航卡住没打 MARK、游戏一直在出图（10-21 维护者：测试的问题不能甩给开发质量）——今天的真局做正反例（tests/fixtures/score_unready，帧表末 700 行 + 关键日志行）
#   丝之歌 silksong_1021143210_2（卡住截图是局内可玩画面）→ 局无效；暗黑3 d3_1021142814_2（自动玩家回退）→ 局无效；巫师3 witcher3_1021140525_2（起局信号 6 崩）→ 照记能玩红
for k in silksong_1021143210_2 d3_1021142814_2 witcher3_1021140525_2; do rm -rf $T/u_$k; cp -R $H/tests/fixtures/score_unready/$k $T/u_$k; done
Ru1=$(sc $T/u_silksong_1021143210_2 --diag=1); IFS=$'\t' read -r _ _ _ pu1 _ <<< "$Ru1"; Ru2=$(sc $T/u_d3_1021142814_2 --diag=1); IFS=$'\t' read -r _ _ _ pu2 _ <<< "$Ru2"
Ru3=$(sc $T/u_witcher3_1021140525_2 --diag=1); IFS=$'\t' read -r _ _ _ pu3 _ <<< "$Ru3"
ck "丝之歌 silksong_1021143210_2 → 局无效「测试未到位：游戏一直在出图」、能玩格「—」（不是红）" '[ "$pu1" = — ] && grep -q "【局无效】测试未到位：游戏一直在出图" <<< "$Ru1"'
ck "暗黑3 d3_1021142814_2 → 局无效「测试未到位」、能玩格「—」" '[ "$pu2" = — ] && grep -q "【局无效】测试未到位：游戏一直在出图" <<< "$Ru2"'
# 同一局换成直连 frames.tsv 列序（graphics/nvn/host_adapt.m：frame / wall_us / disp_us / gpu_us / draw_n / pass_n，没有分配 / GC 列）：复判按列名取，结论不变（改前按位置取第 7 列，直连表越界、复判失效）
rm -rf $T/u_direct; cp -R $H/tests/fixtures/score_unready/silksong_1021143210_2 $T/u_direct
python3 - $T/u_direct/frames.tsv <<'PYEOF'
import csv, sys
r = list(csv.DictReader(open(sys.argv[1]), delimiter='\t')); cols = ['frame', 'wall_us', 'disp_us', 'gpu_us', 'draw_n', 'pass_n']
with open(sys.argv[1], 'w') as f: f.write('\t'.join(cols) + '\n'); f.writelines('\t'.join(x.get(c, '') or '' for c in cols) + '\n' for x in r)
PYEOF
Rd=$(sc $T/u_direct --diag=1); IFS=$'\t' read -r _ _ _ pud _ <<< "$Rd"
ck "直连列序的同一局 → 仍判局无效「测试未到位：游戏一直在出图」" '[ "$pud" = — ] && grep -q "【局无效】测试未到位：游戏一直在出图" <<< "$Rd"'
ck "巫师3 witcher3_1021140525_2（起局崩）→ 不改判、照记能玩红（实为 ${pu3}）" '! grep -q "测试未到位" <<< "$Ru3" && [ "$pu3" != — ]'
# 帧率窗口不完整（MARK 后出图停了）→ 帧率、能耗两格「未测」（10-21 维护者：botw_1021152540_2 读数「— ms / 慢帧 —% / 2.48 W」能耗记了绿，画面停住时功耗自然低是假绿）
rm -rf $T/fw; cp -R $H/tests/fixtures/score_window/botw_1021152540_2 $T/fw; Rw=$(python3 $H/tools/score_cells.py $T/fw --game=botw --commit=x --board=$T/board.tsv --diag=1 2>&1)
ck "窗口不完整（18 秒 524 帧）：帧率「未测」不判红、能耗「未测」不判绿、写明「帧率窗口不完整，不判」" 'grep -q "^# 帧率 未测（窗口不足 55 秒" <<< "$Rw" && grep -q "^# 能耗 未测（2.48 W（帧率窗口不完整，不判）；" <<< "$Rw"'
# 局无效（执行器能判定的基础设施失败）：机上资源包缺文件 → 六格「—」、读数【局无效】；记分板 board.py 不认
cp $L/host.log $L/h0; printf '[gal] 【红】程序：离线库｜读不了 /private/var/mobile/Containers/Data/Application/X/Documents/资源包/shaders/gal.metallib 或 …\n' >> $L/host.log
R=$(sc $L --diag=1); IFS=$'\t' read -r _ _ _ play pic fps pow first alloc rd_ _ <<< "$R"
ck "资源包缺 gal.metallib → 局无效：六格都是「—」" '[ "$play$pic$fps$pow$first$alloc" = "——————" ]'
ck "资源包缺 gal.metallib → 读数以【局无效】开头、写明缺哪个" 'case "$rd_" in "【局无效】机上资源包缺文件（资源包/shaders/gal.metallib）"*) true;; *) false;; esac'
cp $L/h0 $L/host.log; mkdir -p $T/job/out_1; cp $L/* $T/job/out_1/ 2>/dev/null; echo "RESULT=push out=x reason=推 index.tsv 失败" > $T/job/r.txt
R=$(sc $T/job/out_1 --diag=1); ck "执行器 RESULT=push → 局无效" 'grep -q "【局无效】执行器 RESULT=push" <<< "$R"'
echo "RESULT=suspect out=x reason=可疑：系统弹框致前台失焦；类别：软件更新" > $T/job/r.txt
R=$(sc $T/job/out_1 --diag=1); IFS=$'\t' read -r _ _ _ play pic fps pow first alloc _ <<< "$R"
ck "执行器 RESULT=suspect（系统弹框致前台失焦）→ 局无效、六格「—」（不给绿也不记红）" 'grep -q "【局无效】执行器 RESULT=suspect" <<< "$R" && [ "$play$pic$fps$pow$first$alloc" = "——————" ]'
echo "RESULT=red out=x reason=起局 63 秒还没出帧" > $T/job/r.txt; R=$(sc $T/job/out_1 --diag=1); ck "执行器判红（游戏没出帧）不算局无效" '! grep -q "局无效" <<< "$R"'
# 局中见过 MARK、收局拉回的 host.log 空 → 局无效（不是能玩红）
mkdir -p $T/ehl; cp $L/frames.tsv $T/ehl/; : > $T/ehl/host.log; echo "[00:00:01] 窗口起点：起局后 30 秒、第 900 帧（MARK 帧 100），采 60 秒" > $T/ehl/run.log
R=$(sc $T/ehl --diag=1); ck "局中见过 MARK、拉回的 host.log 空 → 【局无效】收局拉回失败" 'grep -q "【局无效】收局拉回失败" <<< "$R"'
# 疑似菜单当成 MARK（10-21 塞尔达 MARK 后每帧 120 次绘制）：本局 MARK 后每帧绘制中位 < 同款其它局中位数的中位数的 1/4 → 局无效；没有可比局不判
mkd() { mkdir -p $1; printf 'S2A 就绪\n[gal] 帧节拍：交换间隔 2，每帧 33.3 ms（30.0 帧/秒）\nS2A 标记 MARK：帧 10\n' > $1/host.log; : > $1/run.log; awk -v n=200 -v d=$2 'BEGIN{print "frame\twall_us\tdraw_n"; for(i=1;i<=n;i++) printf "%d\t33333\t%d\n", i, d}' > $1/frames.tsv; }
mkd $T/jobs/acnh_1021000000_1/out_1 120; R=$(sc $T/jobs/acnh_1021000000_1/out_1 --diag=1); ck "同款没有可比局 → 不判菜单" '! grep -q "疑似菜单" <<< "$R"'
mkd $T/jobs/acnh_1021000100_2/out_1 2046; mkd $T/jobs/acnh_1021000200_1/out_1 3688
R=$(sc $T/jobs/acnh_1021000000_1/out_1 --diag=1); IFS=$'\t' read -r _ _ _ play _ fps pow _ <<< "$R"
ck "MARK 后每帧 120 次绘制、同款基线 3688 → 局无效「疑似菜单」、格都是「—」" 'grep -q "【局无效】疑似菜单当成 MARK" <<< "$R" && [ "$play$fps$pow" = "———" ]'
mkd $T/jobs/acnh_1021000300_1/out_1 2000; R=$(sc $T/jobs/acnh_1021000300_1/out_1 --diag=1); ck "每帧 2000 次绘制（过基线 1/4）→ 不判菜单" '! grep -q "疑似菜单" <<< "$R"'
# 10-22 怪猎 mhrise_1022043503_2：真在村里，MARK 后中位 580；同款场景局 455–1527 随走到哪而变（旧规则「最大值的一半」判成菜单）
for x in 1527:1 1465:2 1289:3 1000:4; do mkd $T/jobs/mhrise_102100000${x#*:}_1/out_1 ${x%:*}; done; mkd $T/jobs/mhrise_1022000000_2/out_1 580
R=$(sc $T/jobs/mhrise_1022000000_2/out_1 --diag=1); ck "怪猎 580、同款场景局 1000–1527 → 不判菜单" '! grep -q "疑似菜单" <<< "$R"'
mkd $T/jobs/mhrise_1022000100_2/out_1 120; R=$(sc $T/jobs/mhrise_1022000100_2/out_1 --diag=1); ck "怪猎 120（不到基线 1/4）→ 判菜单" 'grep -q "【局无效】疑似菜单当成 MARK" <<< "$R"'
# M3 计数按 milestones/M3_*/<款>/ 证据：marked=true 且有 MARK 截图才算；没截图 / marked=false 不算
M=$T/ms; mkdir -p $M/M3_a/acnh $M/M3_a/d3 $M/M3_a/mk8d; echo '{"marked": true}' > $M/M3_a/acnh/ap_summary.json; : > $M/M3_a/acnh/ap_mark.png; echo abc1234 > $M/M3_a/acnh/读数.txt
echo '{"marked": true}' > $M/M3_a/d3/ap_summary.json; echo '{"marked": false}' > $M/M3_a/mk8d/ap_summary.json; : > $M/M3_a/mk8d/ap_mark.png
m3() { S2A_MILESTONES=$M python3 -c "import sys; sys.path.insert(0, '$BD'); import board; print(sum(1 for g in board.GAMES if board.m3(g)), board.m3('acnh')[0])"; }
bck "M3 证据：acnh 有截图算、d3 缺截图不算、mk8d marked=false 不算 → 1 款，提交 abc1234" '[ "$(m3)" = "1 abc1234" ]'
# 判格按同包近 3 个有效局（score_cells.vote；10-21 维护者：取最新一条单局噪声直接翻格）。夹具 = 记分板真实行（5dcfe4994）：
#   怪猎能耗 3.80 红 / 3.54 绿 → 中位 3.67 ≤ 3.7 → 绿、2 局暂定；马车8 3.55 / 3.18 / 4.37 → 中位 3.55 → 绿（取最新会是红）；塞尔达 3.65 / 3.92 → 中位 3.785 → 红
#   稳定：同一组行打乱先后，中位判出的格不变（取最新一条会翻：反证）；事件格多数：马车8 能玩 绿绿绿 → 绿
vt() { python3 - "$H/tools" "$H/tests/fixtures/score_vote/board.tsv" "$1" "$2" <<'PY'
import csv, sys, itertools; sys.path.insert(0, sys.argv[1]); from score_cells import vote
rows = [r for r in csv.reader(open(sys.argv[2]), delimiter='\t')][1:]; g, c = sys.argv[3], sys.argv[4]
rs = [r for r in rows if r[1] == g]; i = ['能玩', '画面', '帧率', '能耗', '首局', '分配'].index(c)
ok = lambda d: '未充电·nominal'   # 能耗读数状态打桩：夹具行的局目录是真机路径，本机 / gate-host 有无不同，单测不读它（状态口径另有用例）
med = {vote(list(p), state=ok)[c][:2] for p in itertools.permutations(rs)}; lastw = {p[-1][3 + i] for p in itertools.permutations(rs)}
print(' '.join(f'{v}{n}' for v, n in sorted(med)), ''.join(sorted(lastw)), vote(rs, state=ok)[c][2])
PY
}
o=$(vt mhrise 能耗); ck "怪猎能耗 3.80 / 3.54：中位判绿 2 局（各种先后都一样）、取最新一条会在红绿间翻；说明 ${o#* * }" '[ "${o%% *}" = 绿2 ] && [ "$(echo $o | cut -d" " -f2)" = 红绿 ] && grep -q "暂定" <<< "$o"'
o=$(vt mk8d 能耗); ck "马车8 能耗 3.55 / 3.18 / 4.37：中位 3.55 判绿 3 局、不暂定（取最新会翻）；说明 ${o#* * }" '[ "${o%% *}" = 绿3 ] && [ "$(echo $o | cut -d" " -f2)" = 红绿 ] && grep -q "中位 3.55 W（3.18–4.37，3 局）" <<< "$o"'
o=$(vt botw 能耗); ck "塞尔达能耗 3.65 / 3.92：中位 3.785 判红（先后不影响）；说明 ${o#* * }" '[ "${o%% *}" = 红2 ] && [ "$(echo $o | cut -d" " -f2)" = 红绿 ]'
o=$(vt mk8d 能玩); ck "马车8 能玩 3 局多数：${o%% *}" '[ "${o%% *}" = 绿3 ]'
o=$(python3 -c "import sys; sys.path.insert(0, '$H/tools'); from score_cells import vote
mk = lambda a, sl, v: ['t', 'mk8d', 'x', '绿', '红', v, '绿', '红', '红', f'16.7 ms / 慢帧 {sl}% / 3.00 W / >100ms 0 / 报红 0 / 自检 — / 平均 {a} 帧/秒（要 60）', '/x', '', '', '']
print(vote([mk('59.70', '0.50', '绿'), mk('58.20', '2.00', '红'), mk('60.00', '0.10', '绿')])['帧率'])")
ck "帧率按中位：平均/要 0.995、0.97、1.0，慢帧 0.5、2、0.1 → 中位 0.995 / 0.50% → 绿：${o}" 'grep -q "^(.绿., 3, .中位 平均/要 0.995、慢帧 0.50%" <<< "$o"'
# 能耗门槛按游戏要的帧率（维护者 10-26 14:1x：60 帧 ≤ 4.8 W，30 帧仍 ≤ 3.7 W）：读数「（要 60）」4.50 W 三局 → 绿、注「门槛 4.8 W（60 帧口径）」；
#   同样 4.50 W「（要 30）」→ 红；4.90 W「（要 60）」→ 红；读数没有「要 N」的旧行 4.50 W → 按 3.7 判红（不放宽旧行）
o=$(python3 -c "import sys; sys.path.insert(0, '$H/tools'); from score_cells import vote
mw = lambda w, tg: ['t', 'g', 'x', '绿', '红', '绿', '绿', '红', '红', f'16.7 ms / 慢帧 0.10% / {w} W / >100ms 0' + (f' / 平均 59.90 帧/秒（要 {tg}）' if tg else ''), '', '', '', '']
print(*[vote([mw(w, tg)] * 3, state=lambda d: '状态未知')['能耗'][0] for w, tg in (('4.50', '60'), ('4.50', '30'), ('4.90', '60'), ('4.50', None))], vote([mw('4.50', '60')] * 3)['能耗'][2])")
ck "能耗门槛按帧率：4.50 W 要 60 → 绿、要 30 → 红、4.90 W 要 60 → 红、旧行无「要」→ 红（${o}）" '[[ "$o" == "绿 红 红 红 "*门槛\ 4.8\ W（60\ 帧口径）* ]]'
# 画面格跨包沿用 维护者 实机判定（10-21 维护者：同包规则让 维护者 判的画面一换包就清零、M2 成「画面未测」）：
#   维护者 判绿（包 A）→ 新包 B 的自动局画面未测 → 画面仍绿、注明「维护者 判 … 包 A」；包 B 自动局画面报红 → 红、注明自动判据报红
J=$T/bj; mkdir -p $J/jobs/acnh_1/out_1 $J/jobs/acnh_2/out_1; for x in 1 2; do printf 'OWNER=%q\n' 自动正式局 > $J/jobs/acnh_$x.job; done
H0=$(head -1 $H/tests/fixtures/score_vote/board.tsv)
bj() { python3 -c "import sys; sys.path.insert(0, '$BD'); import board; board.SB = '$J/b.tsv'; st, last, _ = board.board('通用'); s = st[last['acnh'][0]]; print(s.get('画面', '未测'), '|', s['#注']['画面'][2])"; }
{ echo "$H0"; printf '10-21 08:40\tacnh\tAAA\t绿\t绿\t\t\t\t\t画面：维护者 测试设备1 实机判，包 AAA\t—\t—\t—\t—\n'
  printf '10-21 12:00\tacnh\tBBB\t绿\t未测\t绿\t绿\t红\t绿\t16.7 ms / 慢帧 0.10%% / 3.00 W\t%s/jobs/acnh_1/out_1\t1\t—\t—\n' $J; } > $J/b.tsv
o=$(bj); bck "维护者 判绿（包 AAA）后换新包 BBB：画面仍 绿、注明 维护者 判定（${o}）" '[ "${o%% *}" = 绿 ] && grep -q "维护者 判 10-21 08:40 包 AAA" <<< "$o"'
printf '10-21 13:00\tacnh\tBBB\t绿\t红\t绿\t绿\t红\t绿\t16.7 ms / 慢帧 0.10%% / 3.00 W\t%s/jobs/acnh_2/out_1\t1\t—\t—\n' $J >> $J/b.tsv
o=$(bj); bck "之后新包 BBB 的自动局画面报红 → 画面 红、注明自动判据报红（${o}）" '[ "${o%% *}" = 红 ] && grep -q "之后自动判据 10-21 13:00 包 BBB 报红" <<< "$o"'
# 旧包的自动红不粘住（10-22 维护者：d3 挂着旧包贴边暗带误报的红）：之后新包 EEE 的自动局画面未测（满屏过、真值未测）→ 画面未测、注明旧红作废待 维护者 判；
#   EEE 有一局报红 → 照旧红
cp $J/b.tsv $J/b0.tsv; mkdir -p $J/jobs/acnh_4/out_1 $J/jobs/acnh_5/out_1; for x in 4 5; do printf 'OWNER=%q\n' 自动正式局 > $J/jobs/acnh_$x.job; done
printf '10-21 13:10\tacnh\tEEE\t绿\t未测\t绿\t绿\t红\t绿\t16.7 ms / 慢帧 0.10%% / 3.00 W\t%s/jobs/acnh_4/out_1\t1\t—\t—\n' $J >> $J/b.tsv
o=$(bj); bck "旧包 BBB 自动报红后现行包 EEE 自动局画面未测 → 画面 未测、注明旧红作废待 维护者 判（${o}）" '[ "${o%% *}" = 未测 ] && grep -q "现行包 EEE 的 1 局自动局都没报红 → 旧红作废，待 维护者 判" <<< "$o"'
printf '10-21 13:20\tacnh\tEEE\t绿\t红\t绿\t绿\t红\t绿\t16.7 ms / 慢帧 0.10%% / 3.00 W\t%s/jobs/acnh_5/out_1\t1\t—\t—\n' $J >> $J/b.tsv
o=$(bj); bck "现行包 EEE 有一局画面报红 → 画面 红（${o}）" '[ "${o%% *}" = 红 ] && grep -q "之后自动判据 10-21 13:20 包 EEE 报红" <<< "$o"'
python3 -c "import sys; p=sys.argv[1]; L=[l.rstrip('\n').split('\t') for l in open(p)]; L=[r for r in L if r[0] != '10-21 13:20']
for r in L:
    if '实机判，包 AAA' in r[9]: r[4] = '红'
open(p, 'w').write(''.join('\t'.join(r) + '\n' for r in L))" $J/b.tsv
o=$(bj); bck "维护者 自己判红（包 AAA）、之后 BBB 自动红、现行包 EEE 自动局不报红 → 仍 红（维护者 的红只等 维护者 新判定）（${o}）" '[ "${o%% *}" = 红 ] && ! grep -q 旧红作废 <<< "$o"'
mv $J/b0.tsv $J/b.tsv
printf '10-21 13:30\tacnh\tCCC\t\t绿\t\t\t\t\t画面：维护者 测试设备1 实机判，包 CCC\t—\t—\t—\t—\n' >> $J/b.tsv
o=$(python3 -c "import sys; sys.path.insert(0, '$BD'); import board; board.SB = '$J/b.tsv'; st, last, _ = board.board('通用'); k = last['acnh'][0]; s = st[k]; print(k[1], s.get('帧率', '未测'), s.get('画面', '未测'))")
bck "维护者 又在包 CCC 判画面（之后没有 CCC 的自动局）：现行包仍按自动局定 BBB、帧率照 BBB 判绿、画面取 维护者 新判定绿（${o}）" '[ "$o" = "BBB 绿 绿" ]'
# 现行包 = 最新一条自动正式局的包、无效也算（10-21 维护者：八方2 最新包的局全记局无效后，看板退回显示更早的包当「最新包」）
mkdir -p $J/jobs/acnh_3/out_1; printf 'OWNER=%q\n' 自动正式局 > $J/jobs/acnh_3.job
printf '10-21 14:00\tacnh\tDDD\t—\t—\t—\t—\t—\t—\t【局无效】MARK 打在菜单上 / — ms\t%s/jobs/acnh_3/out_1\t1\t—\t—\n' $J >> $J/b.tsv
o=$(python3 -c "import sys; sys.path.insert(0, '$BD'); import board; board.SB = '$J/b.tsv'; st, last, _ = board.board('通用'); k = last['acnh'][0]; s = st[k]; print(k[1], s.get('能玩', '未测'), s.get('帧率', '未测'))")
bck "最新包 DDD 只有一条局无效：现行包是 DDD、能玩 / 帧率都未测，不退回 BBB（${o}）" '[ "$o" = "DDD 未测 未测" ]'
# 能耗口径（10-23 维护者「在充电 / 充满 / 未充电 / 热机 / 冷机的读数都可以作为依据，标清当时状态就行」）：每局标「充电状态·热档位」，最近 3 个有效局全部投票；期望按规则手算
o=$(python3 - "$H/tools" "$T/eb" <<'PY'
import os, sys, plistlib; sys.path.insert(0, sys.argv[1]); from score_cells import energy_state, vote
R = sys.argv[2]
def mk(n, hb, ch=(False, False), full=(False, False)):   # 窗口第 1000 帧起、1800 帧（到 2800）；心跳 {帧: 热状态}
    d = f'{R}/{n}'; os.makedirs(d, exist_ok=True)
    open(f'{d}/run.log', 'w').write('[x] 窗口起点：起局后 100 秒、第 1000 帧（MARK 帧 900），采 60 秒\n[x] 收局：窗口 60 秒、1800 帧（起局后 160 秒）\n')
    open(f'{d}/host.log', 'w').write(''.join(f'[s2a] [心跳] 帧 {f}，热状态 {k}（0 正常 1 一般 2 严重 3 危急），进程实占 1 MB\n' for f, k in sorted(hb.items())))
    for x, c, fc in zip(('pwh.plist', 'pw1.plist'), ch, full): plistlib.dump({'IORegistry': {'IsCharging': c, 'FullyCharged': fc, 'PowerTelemetryData': {}}}, open(f'{d}/{x}', 'wb'))
    return d
z = {f: 0 for f in range(700, 3000, 300)}
A = mk('A', z); B = mk('B', {**z, 2200: 1}); C = mk('C', {**z, 700: 1}); D = mk('D', z, (False, True)); E = mk('E', {700: 0}); F = mk('F', z, full=(True, True))
for d in (A, B, C, D, E, F): print(os.path.basename(d), energy_state(d), sep='|')
row = lambda d, w, fr='绿': ['t', 'acnh', 'x', '绿', '未测', fr, '绿', '红', '红', f'33.3 ms / 慢帧 0.00% / {w} W', d, '', '', '']
print('AB', vote([row(A, '2.90'), row(B, '2.50')])['能耗'])
print('DD', vote([row(D, '2.40')])['能耗'])
print('ABD', vote([row(A, '3.00'), row(B, '4.20'), row(D, '3.50')])['能耗'])
print('BR', vote([row(B, '2.50', '红')])['能耗'])
old = lambda d, w: ['t', 'acnh', 'x', '绿', '未测', '绿', '未测', '红', '红', f'33.3 ms / 慢帧 0.00% / {w} W（热状态 fair（窗口内最高 1），不判）', d, '', '', '']
print('OB', vote([old(B, '3.90')])['能耗'])
print('CH', vote([row(A, '3.58'), row(B, '3.82'), row(C, '3.87')])['能耗'])
print('HH', vote([row(B, '3.82'), row(C, '3.87')])['能耗'])
nw = lambda d, w: ['t', 'acnh', 'x', '绿', '未测', '未测', '未测', '红', '红', f'— ms / 慢帧 —% / {w} W', d, '', '', '']
print('NW', vote([nw(B, '2.10')])['能耗'])
PY
)
ck "全程 nominal、两端没充电 → 未充电·nominal" 'grep -qx "A|未充电·nominal" <<< "$o"'
ck "窗口内第 2200 帧热状态 1 → 未充电·fair" 'grep -qx "B|未充电·fair" <<< "$o"'
ck "窗口起点前最后一次心跳是 fair → 未充电·fair" 'grep -qx "C|未充电·fair" <<< "$o"'
ck "收局那端 IsCharging=1 → 充电中·nominal" 'grep -qx "D|充电中·nominal" <<< "$o"'
ck "窗口内没有心跳 → 未充电·热状态未知" 'grep -qx "E|未充电·热状态未知" <<< "$o"'
ck "两端 FullyCharged=1（插电充满）→ 充满·nominal" 'grep -qx "F|充满·nominal" <<< "$o"'
ck "充电局 2.40 W 且帧率绿 → 能耗绿、不再「仅供参考」，标充电中·nominal（旧口径：充电档仅供参考）" 'grep -q "^DD (.绿., 1, .中位 2.40 W（2.40–2.40，1 局，暂定）；各状态：充电中·nominal 1 局 中位 2.40 W.)" <<< "$o" && ! grep "^DD" <<< "$o" | grep -q 仅供参考'
ck "未充电 nominal 2.90 + fair 2.50 两局都投票：中位 2.70 绿 2 局，各状态都列（旧口径只按 nominal 2.90 判 1 局）" 'grep -q "^AB (.绿., 2, .中位 2.70 W（2.50–2.90，2 局，暂定）；各状态：未充电·nominal 1 局 中位 2.90 W、未充电·fair 1 局 中位 2.50 W.)" <<< "$o"'
ck "三态 3.00 / 4.20 / 3.50 全投票：中位 3.50 ≤ 3.7 绿 3 局" 'grep -q "^ABD (.绿., 3, .中位 3.50 W（3.00–4.20，3 局）；各状态：" <<< "$o"'
ck "凉机 3.58 + 偏热 3.82 / 3.87 同包：全部中位 3.82 超门槛 → 按凉机 1 局 3.58 判绿（暗黑2 10-24）" 'grep -q "^CH (.绿., 1, .中位 3.82 W.*凉机 1 局中位 3.58 W 为准" <<< "$o"'
ck "只有偏热局 3.82 / 3.87、帧率都保持：不判红 → 未测「偏热，待凉机复测」" 'grep -q "^HH (.未测., 2, .中位 3.84 W.*偏热，待凉机复测" <<< "$o"'
ck "帧率没保持（帧率格红）的局 2.50 W → 能耗红（门槛不变）" 'grep -q "^BR (.红., 1, .中位 2.50 W（2.50–2.50，1 局，暂定，帧率未保持 1 局）" <<< "$o"'
ck "旧行（能耗格写的「未测」、帧率格判了）3.90 W → 认进来（1 局）；只有这局偏热 fair、超门槛 → 不判红，待凉机复测" 'grep -q "^OB (.未测., 1, .中位 3.90 W.*偏热，待凉机复测" <<< "$o"'
ck "帧率窗口无效（帧率格未测）的局有瓦数也不认 → 未测" 'grep -q "^NW (.未测., 0, ..)" <<< "$o"'
# 10-30 iOS 功耗测量口径：① 接着电源、电池不充不放（ExternalConnected=True、IsCharging / FullyCharged=False）→「外接供电」，不再标「未充电」；
#   ② 整机功耗带漏样率：样本约每秒一次，漏样率 = 1 − 样本数 / 窗口秒（run.log「收局：窗口 N 秒」），> 10% 局无效。期望按定义手算
o=$(python3 - "$H/tools" "$T/pm" <<'PY'
import os, sys, plistlib; sys.path.insert(0, sys.argv[1]); from score_cells import energy_state, window_power, window_power_detail, window_power_note
R = sys.argv[2]
def mk(n, ext, n0, n1, load_mw, secs):   # 两端采样：计数 n0 → n1，每样本负载 load_mw 毫瓦
    d = f'{R}/{n}'; os.makedirs(d, exist_ok=True)
    open(f'{d}/run.log', 'w').write(f'[x] 窗口起点：起局后 100 秒、第 1000 帧（MARK 帧 900），采 60 秒\n[x] 收局：窗口 {secs} 秒、3600 帧（起局后 161 秒）\n')
    open(f'{d}/host.log', 'w').write('[s2a] [心跳] 帧 1500，热状态 0（0 正常 1 一般 2 严重 3 危急），进程实占 1 MB\n')
    for x, c in (('pwh.plist', n0), ('pw1.plist', n1)):
        plistlib.dump({'IORegistry': {'IsCharging': False, 'FullyCharged': False, 'ExternalConnected': ext,
                                      'PowerTelemetryData': {'SystemLoadAccumulatorCount': c, 'AccumulatedSystemLoad': c * load_mw}}}, open(f'{d}/{x}', 'wb'))
    return d
G = mk('G', True, 1000, 1060, 3000, 61); U = mk('U', False, 1000, 1060, 3000, 61); M = mk('M', False, 1000, 1050, 3000, 61)
print('G', energy_state(G)); print('U', energy_state(U))
print('Gw', round(window_power(G), 3), window_power_note(G))
print('Mw', window_power(M), window_power_note(M))
PY
)
ck "接着电源、不充不满 → 外接供电·nominal（不再标未充电）" 'grep -qx "G 外接供电·nominal" <<< "$o"'
ck "没接电源、不充不满 → 未充电·nominal" 'grep -qx "U 未充电·nominal" <<< "$o"'
ck "窗口 61 秒、样本 60、每样本 3000 mW → 3.000 W，漏样 1.6%" 'grep -qx "Gw 3.0 窗口 61 秒、样本 60、漏样 1.6%" <<< "$o"'
ck "窗口 61 秒、样本 50 → 漏样 18.0% > 10%：局无效、window_power 为空" 'grep -qx "Mw None 窗口 61 秒、样本 50、漏样 18.0% > 10%，局无效" <<< "$o"'
# 10-30 测量口径修法 4：|中位 − 门槛| < 噪声底 → 不进红绿，记「未测」+「临界·需加局」。噪声表夹具：acnh 0.30 W；mhrise 不在表里 → 取表内最大 0.30
printf '# 款\t噪声底\t局数\t依据\nacnh\t0.30\t3\t夹具\n' > "$T/noise.tsv"
o=$(S2A_AB_NOISE_TSV=$T/noise.tsv python3 - "$H/tools" <<'PY'
import sys; sys.path.insert(0, sys.argv[1]); from score_cells import vote
row = lambda g, w: ['t', g, 'x', '绿', '未测', '绿', '绿', '红', '红', f'33.3 ms / 慢帧 0.00% / {w} W', '', '', '', '']
st = lambda o: '未充电·nominal'
for name, g, ws in (('K1', 'acnh', ('3.60', '3.62', '3.58')), ('K2', 'acnh', ('3.30', '3.35', '3.32')), ('K3', 'acnh', ('3.95', '4.00', '4.05')), ('K4', 'mhrise', ('3.85', '3.90', '3.88'))):
    v = vote([row(g, w) for w in ws], state=st)['能耗']; print(name, v[0], v[1], v[2])
PY
)
ck "acnh 中位 3.60、门槛 3.7、噪声底 0.30：差 0.10 < 0.30 → 未测「临界·需加局」" 'grep -q "^K1 未测 3 .*临界·需加局（|中位 − 门槛| = 0.10 W < 噪声底 0.30 W）" <<< "$o"'
ck "acnh 中位 3.32：差 0.38 ≥ 0.30 → 绿" 'grep -q "^K2 绿 3 " <<< "$o"'
ck "acnh 中位 4.00：差 0.30 不小于 0.30 → 红（边界不算临界）" 'grep -q "^K3 红 3 " <<< "$o"'
ck "mhrise 不在表里：取表内最大 0.30；中位 3.88 差 0.18 → 临界、注明借用" 'grep -q "^K4 未测 3 .*临界·需加局（|中位 − 门槛| = 0.18 W < 噪声底 0.30 W，本款无噪声底、取表内最大）" <<< "$o"'


# 直连局（10-25 维护者定）：分配闸门只看 alloc_b / gc0 / gc1（+ gc2 / gc_pause_us），不要 rb_us——读回同步是通用渲染器才有的环节。表头同直连 frames.tsv（graphics/nvn/host_adapt.m）
mkr() { mkdir -p $1; awk -v al=$2 'BEGIN{print "frame\twall_us\tdisp_us\tgpu_us\tdraw_n\tpass_n\talloc_b\tgc0\tgc1\tgc2\tgc_pause_us"; for(i=1;i<=3000;i++) printf "%d\t33333\t33333\t9000\t4000\t40\t%d\t0\t0\t0\t%d\n", i, al, (i==50?2000:0)}' > $1/frames.tsv; printf '%s\n' "$3" > $1/host.log; }
mkr $T/dr 160 '[s2a] 图形模式：直连（依据 环境变量 S2A_GFX=direct；程序号 01006f8002326000）'
ck "直连局、缺 rb_us、每帧 160 B、停顿 2 ms → 判（绿，说明写读回不判）" '[ "$(python3 $H/tools/frame_gate.py $T/dr --fps=30 --mark=100 | cut -f1)" = 绿 ] && python3 $H/tools/frame_gate.py $T/dr --fps=30 --mark=100 | grep -q "读回 直连无此环节"'
mkr $T/dr2 5000 '[s2a] 图形模式：直连（依据 环境变量 S2A_GFX=direct；程序号 01006f8002326000）'
ck "直连局、缺 rb_us、每帧 5000 B > 4096 → 红（不看读回也照判分配）" '[ "$(python3 $H/tools/frame_gate.py $T/dr2 --fps=30 --mark=100 | cut -f1)" = 红 ]'
mkr $T/gr 160 '[s2a] 图形模式：通用（依据 缺省；程序号 01006f8002326000）'
ck "通用局、缺 rb_us → 仍未测（缺列 rb_us）" '[ "$(python3 $H/tools/frame_gate.py $T/gr --fps=30 --mark=100 | cut -f1)" = 未测 ] && python3 $H/tools/frame_gate.py $T/gr --fps=30 --mark=100 | grep -q "缺列 rb_us"'
rm -rf $T; [ $bad = 0 ] && echo "score 单测全过" || { echo "score 单测有不通"; exit 1; }
