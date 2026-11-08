#!/bin/bash
# 门禁覆盖：tools/disk_admit.py tools/tianyan_lane.py tools/census/census.sh
# 工作盘准入单测（11-06 天眼回传 / 普查本机打包绕过 packq 准入，15 分钟 118 → 73G）：临时账本 + 假剩余，不读真盘。
# 期望（按规则手写）：剩余 100、最低 50
#   ① 预计 40 → 放行，命令照跑，退出码透传（命令退 3 → 3）
#   ② 账内已有活着的 40G 预留 → 再来 40 排不上：等满（--max-wait 2）退 75，命令没跑
#   ③ 持有进程死了 → 旧预留作废，40 放行
#   ④ --measure 目录实际 3 MB → est.tsv 记 1.0G（下限 1），下次不给 --gb 就按 1 算 → 剩 60 时也放行
#   ⑤ 两单同时来、各 40（剩 100）→ 一个跑完另一个才开（不同时挤进去）
#   ⑦ 入口闸经 disk_admit.py 重起入口脚本；⑧ 入口闸写的不在本机工作盘（本机没有工作盘）→ 不排队直接跑
#   ⑥ S2A_DISK_ADMIT=off → 没余量也直接跑、打【黄】
#   ⑲ --measure 实占按 APFS 独占字节：克隆进来的输入（cp -c）不计，新写的照计
#   ⑩ 账内只算还没写的：剩 50.03、持有者预留 0.02 且实测目录已写 25 MB → 再来 0.02 放行（50.03 − 0 − 0.02 ≥ 50）；负对照：目录空 → 50.03 − 0.02 − 0.02 < 50 排不上
#   ⑪ 嵌套不叠加：外层 run 预留 40（剩 100）里再 run 40 → 组内 max(40, 40) = 40，放行；里层要 60 → 组内 60、100 − 60 < 50 排不上
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0; PIDS=
trap 'for p in $PIDS; do kill $p 2> /dev/null; done; rm -rf "$T"' EXIT
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
export S2A_DISK_DIR=$T/acct S2A_DISK_FREE_GB=100 S2A_DISK_MIN_FREE_GB=50 S2A_DISK_EST_GB=40 S2A_LAYOUT_ENV=/dev/null
export S2A_DISK_WORK=$T   # 工作盘 = 临时目录所在卷（实测目录都在这卷上，记工作盘那本账；⑯ 另测跨卷）
DA="python3 $H/tools/disk_admit.py"
$DA run --cat c --name a --gb 40 -- bash -c 'touch '$T'/ran1; exit 3' 2> $T/e1; r1=$?
ck "① 够就放行、命令照跑、退出码透传（rc ${r1}）" '[ $r1 = 3 ] && [ -f $T/ran1 ] && [ -z "$(ls $T/acct | grep ^use.)" ]'
# ② 起一个持有者：它自己排到 40G 后睡着
$DA run --cat c --name holder --gb 40 -- sleep 30 2> /dev/null & HP=$!; PIDS="$PIDS $HP"
for i in $(seq 50); do ls $T/acct 2> /dev/null | grep -q ^use. && break; sleep 0.1; done
$DA run --cat c --name b --gb 40 --max-wait 2 --poll 1 -- touch $T/ran2 2> $T/e2; r2=$?
ck "② 账内已有 40、再来 40 → 等满退 75（rc ${r2}）、命令没跑、报排不上" '[ $r2 = 75 ] && [ ! -f $T/ran2 ] && grep -q "排不上" $T/e2'
# ③ 持有者死了：kill 它（python 进程与子 sleep），预留文件留着但进程不在 → 作废
pkill -P $HP 2> /dev/null; kill $HP 2> /dev/null; wait $HP 2> /dev/null; sleep 0.3
$DA run --cat c --name b --gb 40 --max-wait 2 --poll 1 -- touch $T/ran3 2> /dev/null; r3=$?
ck "③ 持有者死了 → 旧预留作废、40 放行（rc ${r3}）" '[ $r3 = 0 ] && [ -f $T/ran3 ]'
# ④ 实测记账
mkdir -p $T/out; dd if=/dev/zero of=$T/out/f bs=1m count=3 2> /dev/null
$DA run --cat c --name game1 --measure $T/out -- true 2> /dev/null
S2A_DISK_FREE_GB=60 $DA run --cat c --name game1 --max-wait 1 --poll 1 -- touch $T/ran4 2> /dev/null; r4=$?
ck "④ 实测记进 est.tsv（$(tail -1 $T/acct/est.tsv 2> /dev/null | tr '\t' ' ')），下次按它算、剩 60 也放行（rc ${r4}）" 'grep -q "^game1	1.0	c$" $T/acct/est.tsv && [ $r4 = 0 ] && [ -f $T/ran4 ]'
# ⑤ 同时来两单
( $DA run --cat c --name x --gb 40 --poll 0.2 -- bash -c "date +%s.%N > $T/x0; sleep 2; date +%s.%N > $T/x1" 2> /dev/null ) & P1=$!
( $DA run --cat c --name y --gb 40 --poll 0.2 -- bash -c "date +%s.%N > $T/y0; sleep 2; date +%s.%N > $T/y1" 2> /dev/null ) & P2=$!
wait $P1 $P2
ov=$(python3 -c "
a0,a1,b0,b1=[float(open('$T/'+n).read()) for n in ('x0','x1','y0','y1')]
print('不重叠' if a1 <= b0 + 0.05 or b1 <= a0 + 0.05 else '重叠')")
ck "⑤ 两单各 40（剩 100）同时来 → 一个跑完另一个才开（${ov}）" '[ "$ov" = 不重叠 ]'
S2A_DISK_ADMIT=off S2A_DISK_FREE_GB=10 $DA run --cat c --name z --gb 40 -- touch $T/ran6 2> $T/e6; r6=$?
ck "⑥ 准入关 → 没余量也直接跑、打黄（rc ${r6}）" '[ $r6 = 0 ] && [ -f $T/ran6 ] && grep -q "【黄】" $T/e6'
# ⑦ 入口闸（tools/disk_admit_gate.sh，dev_run.sh / run_mac.sh 录帧时 source）：入口脚本经闸重起自己 → 跑起来时 S2A_DISK_HELD=1、账上有它这一单；外层已在准入里（S2A_DISK_HELD=1）→ 直接跑、不重起
printf '#!/bin/bash\n. %s/tools/disk_admit_gate.sh; disk_admit_gate 真机局 job7 %s/out "$0" "$@"\necho "held=$S2A_DISK_HELD args=$*"; ls %s/acct | grep -c "^use\\." \n' "$H" "$T" "$T" > $T/entry.sh
o7=$(S2A_DISK_WORK=$T bash $T/entry.sh a b 2> /dev/null | tr '\n' ' '); o7b=$(S2A_DISK_HELD=1 bash $T/entry.sh c 2> /dev/null | tr '\n' ' ')
ck "⑦ 入口闸：经闸重起后 held=1、参数原样、跑时账上 1 单（${o7}）；外层已在准入里直接跑（${o7b}）" '[ "$o7" = "held=1 args=a b 1 " ] && [ "$o7b" = "held=1 args=c 0 " ]'
# ⑧ 写的不在本机工作盘上（11-06 ssh_argv_test 退回：mini 远端根里跑 dev_run.sh，那边没有运行区 roots）→ 不排队、不记账，命令照跑；剩余 10G 也放行
o8=$(S2A_DISK_WORK=$T/没有这个盘 S2A_DISK_FREE_GB=10 bash $T/entry.sh d 2> /dev/null | tr '\n' ' ')
S2A_DISK_WORK=$T S2A_DISK_FREE_GB=10 timeout 5 bash $T/entry.sh e > $T/o8b 2> /dev/null; r8b=$?; o8b=$(tr '\n' ' ' < $T/o8b)
ck "⑧ 本机没有工作盘 → 直接跑、账上 0 单（${o8}）；负对照：在工作盘上、剩 10G → 排队没跑（退出 ${r8b}，输出「${o8b}」）" '[ "$o8" = "held=1 args=d 0 " ] && [ -z "$o8b" ] && [ $r8b = 124 ]'
# ⑨ 子进程拿调用方原样的区域（11-06 手测脚本经准入重起后「装测试机 + 变量 DEV + 全角括号」报 DEV�: unbound variable）：调用方没设区域 → 子进程环境里也没有 LC_CTYPE（Python 区域强转加的 C.UTF-8 不外泄），
#   脚本里「变量紧跟全角字」照常展开；负对照：子进程显式带 LC_CTYPE=C.UTF-8 → 同一脚本报 unbound
printf '#!/bin/bash\nset -u\nDEV=2\necho "装测试机%sDEV）"\n' '$' > $T/loc.sh   # 夹具故意写「变量紧跟全角字」；用 %s 拼出 $，仓库源码里不留这种写法
o9=$(env -u LANG -u LC_ALL -u LC_CTYPE S2A_DISK_FREE_GB=100 python3 $H/tools/disk_admit.py run --cat c --name loc --gb 1 -- bash -c 'echo "ct=${LC_CTYPE:-无}"; bash '$T'/loc.sh' 2>&1 | tr '\n' ' ')
o9n=$(env -u LANG -u LC_ALL LC_CTYPE=C.UTF-8 bash $T/loc.sh 2>&1 | tr '\n' ' ')
ck "⑨ 调用方没设区域 → 子进程也没有 LC_CTYPE、全角字紧跟变量照常（${o9}）；负对照带 C.UTF-8 报错（${o9n:0:60}）" '[ "$o9" = "ct=无 装测试机2） " ] && grep -q "unbound variable" <<< "$o9n"'
# ⑩ 嵌套（11-06 金刚 c3：外层 run 记 40G、里面天眼道 hold 同一单再排 40G，剩 159 − 98 − 40 < 50 自己挡自己）：剩 100、外层 40 排到后里面再套 run 40 →
#   期望（按规则手写）：里层不排队直接跑、退出码透传、跑时账上只 1 单（外层那笔）；负对照：同样的里层不在外层里（另起、不带 S2A_DISK_HELD）且外层占着 → 等满退 75
o10=$($DA run --cat c --name outer --gb 40 -- bash -c "$DA run --cat c --name inner --gb 40 --max-wait 2 --poll 1 -- bash -c 'ls $T/acct | grep -c ^use\\.; exit 4' 2> $T/e10; echo rc=\$?" 2> /dev/null | tr '\n' ' ')
$DA run --cat c --name outer2 --gb 40 -- sleep 30 2> /dev/null & HP2=$!; PIDS="$PIDS $HP2"
for i in $(seq 50); do ls $T/acct 2> /dev/null | grep -q ^use. && break; sleep 0.1; done
env -u S2A_DISK_HELD $DA run --cat c --name inner2 --gb 40 --max-wait 2 --poll 1 -- touch $T/ran10 2> /dev/null; r10n=$?
pkill -P $HP2 2> /dev/null; kill $HP2 2> /dev/null; wait $HP2 2> /dev/null
ck "⑩ 嵌套：里层不排队直接跑、账上 1 单、退出码透传（${o10}）；负对照不在外层里 → 退 ${r10n}、没跑" '[ "$o10" = "1 rc=4 " ] && ! grep -q "排队\|排不上" $T/e10 && grep -q "外层已预留" $T/e10 && [ $r10n = 75 ] && [ ! -f $T/ran10 ]'
# ⑪ 账内只算还没写的（11-06 准入卡单：已写字节剩余里扣过一次、预留再扣一次）：剩 50.03、持有者预留 0.02 且实测目录已写 25 MB → 另一单 0.02 放行（50.03 − 0 − 0.02 ≥ 50）；负对照目录空 → 50.03 − 0.02 − 0.02 < 50 排不上
mkdir -p $T/w11 $T/w11n; dd if=/dev/zero of=$T/w11/f bs=1m count=25 2> /dev/null
for d in w11 w11n; do
  S2A_DISK_FREE_GB=50.03 $DA run --cat c --name h$d --gb 0.02 --measure $T/$d -- bash -c "env -u S2A_DISK_HELD -u S2A_DISK_HOLD S2A_DISK_FREE_GB=50.03 $DA run --cat c --name n$d --gb 0.02 --max-wait 1 --poll 1 -- true" 2> /dev/null; eval r_$d=\$?
done
ck "⑪ 已写 25 MB 的预留不再算 → 放行（rc ${r_w11}）；负对照目录空 → 排不上（rc ${r_w11n}）" '[ $r_w11 = 0 ] && [ $r_w11n = 75 ]'
# ⑫ 外层预留里提的单（packq 执行器不是子孙，按 parent 记子单）：剩 100、外层 40 → 子单 40 组内 max(40, 40) 放行；子单 60 → 组内 60、100 − 60 < 50 排不上；不带 parent 的 40 → 100 − 40 − 40 < 50 排不上
o12=$($DA run --cat c --name outer --gb 40 -- env -u S2A_DISK_HELD python3 -c "
import os, sys; sys.path.insert(0, '$H/tools'); import disk_admit as d; par = os.environ['S2A_DISK_HOLD']
print(*[d.reserve('c', n, gb=g, wait=False, parent=pa, log=lambda s: None) is not None for n, g, pa in (('k40', 40, par), ('k60', 60, par), ('free40', 40, None))])" 2> /dev/null)
ck "⑫ 子单 40 放行、子单 60 排不上、不带 parent 的 40 排不上（${o12}）" '[ "$o12" = "True False False" ]'
# ⑬ 进程启动时刻按 C 区域比（11-06 中文区域调用方把活着的预留当死单删）：中文区域起持有者、英文区域打账 → 账上 1 单；反过来也是 1 单
rm -f $T/acct/use.*
for l in "zh_CN.UTF-8 en_US.UTF-8" "en_US.UTF-8 zh_CN.UTF-8"; do set -- $l
  LC_ALL=$1 $DA run --cat c --name loc13 --gb 1 -- sleep 30 2> /dev/null & HP3=$!; PIDS="$PIDS $HP3"
  for i in $(seq 50); do ls $T/acct 2> /dev/null | grep -q "^use\.$HP3\." && break; sleep 0.1; done
  eval "o13_${1%%_*}=\$(LC_ALL=$2 $DA status | sed -n 's/.*账内 \\([0-9]*\\) 单.*/\\1/p')"
  pkill -P $HP3 2> /dev/null; kill $HP3 2> /dev/null; wait $HP3 2> /dev/null
done
ck "⑬ 中文区域写、英文区域读 → ${o13_zh} 单；英文写、中文读 → ${o13_en} 单" '[ "$o13_zh" = 1 ] && [ "$o13_en" = 1 ]'
# ⑭ 新名字按同类别最近一次实测（11-06 真机局新作业目录名吃缺省 40G 空排队）：真机局 job_a 实测 3 MB（记 1.0）后，新名字 job_b 预计 = 1（剩 60、最低 50 放行）；
#   负对照：账本里一条实测都没有时，新类别 other 的新名字按缺省 40 → 60 − 40 < 50 排不上；旧两列行（无类别）照读
mkdir -p $T/j14; dd if=/dev/zero of=$T/j14/f bs=1m count=3 2> /dev/null
$DA run --cat 真机局 --name job_a --measure $T/j14 -- true 2> /dev/null
S2A_DISK_FREE_GB=60 $DA run --cat 真机局 --name job_b --max-wait 1 --poll 1 -- true 2> /dev/null; r14=$?
mkdir -p $T/acct14e; S2A_DISK_DIR=$T/acct14e S2A_DISK_FREE_GB=60 $DA run --cat other --name job_c --max-wait 1 --poll 1 -- true 2> /dev/null; r14n=$?
ck "⑭ 同类别新名字按实测 1G 放行（rc ${r14}，est 行「$(grep ^job_a $T/acct/est.tsv | tr '\t' ' ')」）；空账本新类别按缺省 40 排不上（rc ${r14n}）" '[ $r14 = 0 ] && grep -q "^job_a	1.0	真机局$" $T/acct/est.tsv && [ $r14n = 75 ]'
# ⑮ 先来先得（11-06 金刚 c3 回传排 1 个半小时，空位反复被后到的小单先拿走）：剩 100、最低 50，A 占 40；B 要 40 先排队（100 − 40 − 40 < 50）；
#   之后到的 C 要 10：算上 B 的 40 → 100 − 40 − 40 − 10 < 50 排不上（退 75）；负对照：没有 B 排队时 C 的 10 放行（100 − 40 − 10 ≥ 50）
rm -f $T/acct/use.* $T/acct/wait.*
$DA run --cat c --name A15 --gb 40 -- sleep 8 2> /dev/null & HA=$!; PIDS="$PIDS $HA"
for i in $(seq 50); do ls $T/acct | grep -q "^use\.$HA\." && break; sleep 0.1; done
$DA run --cat c --name C15n --gb 10 --max-wait 1 --poll 1 -- true 2> /dev/null; r15n=$?
$DA run --cat c --name B15 --gb 40 --poll 1 -- true 2> /dev/null & HB=$!; PIDS="$PIDS $HB"
for i in $(seq 50); do ls $T/acct | grep -q "^wait\.$HB\." && break; sleep 0.1; done
$DA run --cat c --name C15 --gb 10 --max-wait 1 --poll 1 -- true 2> /dev/null; r15=$?
st15=$($DA status | grep -c "排队 c/B15")
kill $HA $HB 2> /dev/null; pkill -P $HA 2> /dev/null; wait $HA $HB 2> /dev/null
ck "⑮ B 先排队时后到的 C 不插队（rc ${r15}、status 列出排队 B ${st15} 行）；负对照没人排队时 C 放行（rc ${r15n}）" '[ $r15 = 75 ] && [ $r15n = 0 ] && [ "$st15" = 1 ]'
# ⑯ 按卷记账（11-06 S2A_2T 满、内置盘空，主线回归 reg16 0 款出包）：工作盘假装是另一个系统卷 ${WV}（macOS 的 /System/Volumes/VM 等，与临时目录不同卷），工作盘剩 10、账内一单 40 —
#   实测目录在临时目录（另一卷，剩 100、保底 60）的单要 30 → 只看那一卷：100 − 30 ≥ 60 放行；要 50 → 100 − 50 < 60 排不上；status 分两本账
WV=$(python3 -c 'import os,sys
for p in ("/System/Volumes/VM", "/System/Volumes/Preboot", "/System/Volumes/Update", "/boot", "/"):
    if os.path.isdir(p) and os.stat(p).st_dev != os.stat(sys.argv[1]).st_dev: print(p); break' "$T")
if [ -n "$WV" ]; then
  rm -f $T/acct/use.* $T/acct/wait.*; mkdir -p $T/v16
  S2A_DISK_WORK=$WV S2A_DISK_FREE_GB=100 $DA run --cat c --name w16 --gb 40 -- sleep 6 2> /dev/null & HW=$!; PIDS="$PIDS $HW"
  for i in $(seq 50); do ls $T/acct | grep -q "^use\.$HW\." && break; sleep 0.1; done
  S2A_DISK_WORK=$WV S2A_DISK_FREE_GB=10 S2A_DISK_FREE_OTHER_GB=100 $DA run --cat c --name o16 --gb 30 --measure $T/v16 --max-wait 1 --poll 1 -- true 2> /dev/null; r16=$?
  S2A_DISK_WORK=$WV S2A_DISK_FREE_GB=10 S2A_DISK_FREE_OTHER_GB=100 $DA run --cat c --name o16n --gb 50 --measure $T/v16 --max-wait 1 --poll 1 -- true 2> /dev/null; r16n=$?
  S2A_DISK_WORK=$WV S2A_DISK_FREE_GB=10 $DA run --cat c --name w16n --gb 1 --max-wait 1 --poll 1 -- true 2> /dev/null; r16w=$?
  kill $HW 2> /dev/null; pkill -P $HW 2> /dev/null; wait $HW 2> /dev/null
  ck "⑯ 别的卷上的单只看那一卷：要 30 放行（rc ${r16}）、要 50 排不上（rc ${r16n}）；工作盘那本照旧满（要 1 排不上 rc ${r16w}）" '[ $r16 = 0 ] && [ $r16n = 75 ] && [ $r16w = 75 ]'
else echo "通 ⑯ 跳过：本机 / 与临时目录同一卷，造不出第二卷"; fi
# ⑰ 有界回填（11-07 总指挥拍板）：剩 100、最低 50，A 占 40，大单 B 要 40 排队（100 − 40 − 40 < 50）。
#   ① 小单 2G、2G、1G 依次来：不算 B 时 100 − 40 − 小单 ≥ 50 → 回填放行（status 标「回填」）；② 回填合计已 5G，第 4 张 1G 要排队（5 + 1 > 5，退 75）；
#   ③ A 结束、空间够 → B 照常放行（不是回填）；负对照：没有排队者时 1G 单走正常放行、不标回填
rm -f $T/acct/use.* $T/acct/wait.*
$DA run --cat c --name A17 --gb 40 -- sleep 15 2> /dev/null & HA=$!; PIDS="$PIDS $HA"
for i in $(seq 50); do ls $T/acct | grep -q "^use\.$HA\." && break; sleep 0.1; done
$DA run --cat c --name n17 --gb 1 --max-wait 1 --poll 1 -- true 2> $T/e17n; r17n=$?
$DA run --cat c --name B17 --gb 40 --poll 1 -- true 2> $T/e17b & HB=$!; PIDS="$PIDS $HB"
for i in $(seq 50); do ls $T/acct | grep -q "^wait\.$HB\." && break; sleep 0.1; done
HS=; for g in 2 2 1; do $DA run --cat c --name s17_$g --gb $g --max-wait 1 --poll 1 -- sleep 6 2>> $T/e17s & HS="$HS $!"; PIDS="$PIDS $!"; sleep 0.6; done
for i in $(seq 50); do [ "$($DA status | grep -c '（回填）')" = 3 ] && break; sleep 0.1; done; n17=$($DA status | grep -c '（回填）')
$DA run --cat c --name s17_4 --gb 1 --max-wait 1 --poll 1 -- true 2> /dev/null; r17_4=$?
ck "⑰① B 等空间时 3 张小单回填先跑（status 回填 ${n17} 行）；负对照没人排队时 1G 不标回填（rc ${r17n}）" '[ "$n17" = 3 ] && [ $r17n = 0 ] && ! grep -q 回填 $T/e17n'
ck "⑰② 回填合计已 5G，第 4 张 1G 排队（rc ${r17_4}，期望 75）" '[ $r17_4 = 75 ]'
kill $HA 2> /dev/null; pkill -P $HA 2> /dev/null; wait $HA 2> /dev/null
for i in $(seq 80); do kill -0 $HB 2> /dev/null || break; sleep 0.1; done; wait $HB; r17b=$?
for p in $HS; do kill $p 2> /dev/null; pkill -P $p 2> /dev/null; done; wait $HS 2> /dev/null
ck "⑰③ A 结束后大单 B 照常放行、不是回填（rc ${r17b}）" '[ $r17b = 0 ] && grep -q "排到" $T/e17b && ! grep -q 回填 $T/e17b'
# ⑱ 预计取 p80（11-07 总指挥：原「同类最近一次」被最后一条 27.5G 带偏，新真机局全按 28G 排；中位数会让一半低估）。期望手算：
#   同类最近 20 次 = 15 次 1G + 5 次 28G → 排序第 16 位（⌈20×0.8⌉）= 28；16 次 1G + 4 次 28G → 第 16 位 = 1；
#   只看最近 20 次：前面 10 条 28G、后面 20 条 1G → 1；本名有记录用本名（job_x 记 3.0 → 3.0）；新类别 → 全部类别最近 20 次的 p80
e18() { mkdir -p "$T/a18"; : > "$T/a18/est.tsv"; local n v c; while read -r n v c; do printf '%s\t%s\t%s\n' "$n" "$v" "$c" >> "$T/a18/est.tsv"; done; }
q18() { S2A_DISK_DIR=$T/a18 python3 -c 'import sys;sys.path.insert(0,sys.argv[1]);import disk_admit as d;print(d.est_gb(sys.argv[2],sys.argv[3]))' "$H/tools" "$1" "$2"; }
{ for i in $(seq 15); do echo "a$i 1.0 真机局"; done; for i in $(seq 5); do echo "b$i 28.0 真机局"; done; } | e18; v1=$(q18 真机局 new1)
{ for i in $(seq 16); do echo "a$i 1.0 真机局"; done; for i in $(seq 4); do echo "b$i 28.0 真机局"; done; } | e18; v2=$(q18 真机局 new2)
{ for i in $(seq 10); do echo "o$i 28.0 真机局"; done; for i in $(seq 20); do echo "a$i 1.0 真机局"; done; echo "job_x 3.0 真机局"; } | e18; v3=$(q18 真机局 new3); v4=$(q18 真机局 job_x); v5=$(q18 录帧 new5)
ck "⑱ p80：15×1+5×28 → ${v1}（期望 28）；16×1+4×28 → ${v2}（期望 1）；只看最近 20 → ${v3}（期望 1）；本名 → ${v4}（期望 3.0）；新类别取全类 p80 → ${v5}（期望 1）" '[ "$v1" = 28.0 ] && [ "$v2" = 1.0 ] && [ "$v3" = 1.0 ] && [ "$v4" = 3.0 ] && [ "$v5" = 1.0 ]'
# ⑲ 实占按 APFS 独占字节（11-07 总指挥：真机局作业目录 cp -cR 资源包，克隆几乎不占盘，du 按满额记 27.5G，新真机局全按 28G 排堵死）。
#   期望手算：目录里 64 MB 克隆（源在目录外、仍在）+ 2 MB 新写 → 实占 ≈ 2 MB（< 0.01G）；夹具自证：du -sk 表观 ≥ 64 MB（按表观算 → 红）
mkdir -p $T/c19/src $T/c19/job/pack; mkfile 64m $T/c19/src/big 2> /dev/null || dd if=/dev/zero of=$T/c19/src/big bs=1m count=64 2> /dev/null
c19=; if [ "$(uname)" != Darwin ]; then :
else c19=1; if ! cp -c $T/c19/src/big $T/c19/job/pack/big 2> /dev/null; then c19=; fi; fi
if [ -z "${c19:-}" ]; then echo "⑲ 跳过：本机临时目录不支持克隆（非 APFS）"
else
  dd if=/dev/urandom of=$T/c19/job/out_1.png bs=1m count=2 2> /dev/null
  g19=$(python3 -c 'import sys;sys.path.insert(0,sys.argv[1]);import disk_admit as d;print(f"{d.du_gb(sys.argv[2]):.4f}")' "$H/tools" $T/c19/job); k19=$(du -sk $T/c19/job | cut -f1)
  ck "⑲ 克隆输入不计：实占 ${g19}G（期望 ≈0.002，< 0.01）；夹具表观 ${k19} KB（期望 ≥ 65536，按表观算就红）" 'awk "BEGIN{exit !($g19 >= 0.0015 && $g19 < 0.01)}" && [ $k19 -ge 65536 ]'
fi
[ $bad = 0 ] && echo "disk_admit 单测全过"; exit $bad
