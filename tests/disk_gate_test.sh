#!/bin/bash
# 磁盘判定 + 回收单测（10-25 盘满事故；约 5 秒）：bash tests/disk_gate_test.sh
# 期望（按规则手写，不跑被测实现推）：
#   ① tools/disk_low.sh：可用 120 G → 打「磁盘不足：可用 120 G < 130 G」退出 0；135 G → 不打、退出 1；阈值 S2A_MIN_FREE_GB=150 时 135 G 也算不足
#   ⑤ 看板（tools/board.py）：120 G → 有「🔴 磁盘不足：可用 120 G < 130 G」行；135 G → 没有
#   ⑥ gc 局目录：超过 12 小时、没被记分板引用、没 .keep → 删；被记分板「局目录」列引用的、带 .keep 的、12 小时内的 → 留
#   ⑦ gc 产物根：现行 c + 上一版 b 留，更旧的 a 删；持有者已死且 2 小时没动的 .tmp 删，持有者活着的 .tmp 留
#   ⑧ gc 锁：锁里的 pid 活着但起始时间对不上（pid 被复用，10-25 mini gc 因此一直跳过）→ 照跑；起始时间对得上（对方真在跑）→ 跳过
#   ⑨ 看板远端：mini 可用 20 G（远端阈值 30）→ 报红「mini 磁盘不足」（并在 ⑤）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0; trap 'kill $LIVE 2> /dev/null; chmod -R u+w "$T"; rm -rf "$T"' EXIT; LIVE=
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
export S2A_MIN_FREE_GB=130
# ①
o1=$(S2A_DISK_FREE_G=120 bash $H/tools/disk_low.sh); r1=$?; o2=$(S2A_DISK_FREE_G=135 bash $H/tools/disk_low.sh); r2=$?; S2A_DISK_FREE_G=135 S2A_MIN_FREE_GB=150 bash $H/tools/disk_low.sh > /dev/null; r3=$?
ck "① 120 G 不足（rc=${r1}「${o1}」）、135 G 够（rc=${r2}）、阈值 150 时 135 G 不足（rc=${r3}）" '[ $r1 = 0 ] && [ "$o1" = "磁盘不足：可用 120 G < 130 G" ] && [ $r2 = 1 ] && [ -z "$o2" ] && [ $r3 = 0 ]'
# ⑤
b1=$(S2A_DISK_WATCH= S2A_DISK_FREE_G=120 python3 $H/tools/board.py 2> /dev/null | grep -c "🔴 磁盘不足：可用 120 G < 130 G"); b2=$(S2A_DISK_WATCH= S2A_DISK_FREE_G=135 python3 $H/tools/board.py 2> /dev/null | grep -c "磁盘不足")
b3=$(S2A_MACHINE_NO_LOCAL=1 S2A_DISK_WATCH=mini S2A_REMOTE_DEFAULT=fake-mini S2A_REMOTE_HOSTS= S2A_DISK_FREE_G=135 S2A_DISK_FREE_G_REMOTE=20 python3 $H/tools/board.py 2> /dev/null | grep -c "🔴 mini 磁盘不足：可用 20 G < 30 G：不往这台派活")
ck "⑤ 看板：本机 120 G 报红 ${b1} 行；135 G ${b2} 行；mini 20 G（远端阈值 30）报红 ${b3} 行" '[ "$b1" = 1 ] && [ "$b2" = 0 ] && [ "$b3" = 1 ]'
# ⑥⑦ gc（临时运行目录；工作树 / 仓库 / 缓存一律临时，盘余量假定充足，同 tests/gc_test.sh）
export S2A_WT_ROOT=$T/wt S2A_REPO=$T/repo2 S2A_BOARD=$T/board.tsv S2A_GC_FREE_GB=999 GAL_PSO_CACHE=$T/pc GAL_AIR_CACHE=$T/air GAL_DL_CACHE=$T/dl
R=$T/run; J=$R/sched/jobs; mkdir -p $J $R/roots
old() { python3 -c "import os,sys,time;t=time.time()-float(sys.argv[1])*3600
for p in sys.argv[2:]:
  for d,ds,fs in os.walk(p):
    for x in ds+fs: os.utime(os.path.join(d,x),(t,t),follow_symlinks=False)
  os.utime(p,(t,t),follow_symlinks=False)" "$@"; }
for j in acnh_1_1 acnh_2_1 acnh_3_1 acnh_4_1; do mkdir -p $J/$j; echo RESULT=done > $J/$j/r.txt; done; : > $J/acnh_3_1/.keep
old 13 $J/acnh_1_1 $J/acnh_2_1 $J/acnh_3_1; old 1 $J/acnh_4_1
printf 'c1\tc2\tc3\tc4\tc5\tc6\tc7\tc8\tc9\tc10\t%s\n' "$J/acnh_2_1" > $T/board.tsv
for v in a b c; do mkdir -p $R/roots/acnh@$v/romfs; echo $v > $R/roots/acnh@$v/romfs/f; done; old 5 $R/roots/acnh@a; old 4 $R/roots/acnh@b; ln -s acnh@c $R/roots/acnh@现行
mkdir -p $R/roots/acnh@dead.tmp $R/roots/acnh@live.tmp; sleep 120 & LIVE=$!; echo "$LIVE $(ps -o lstart= -p $LIVE | awk '{$1 = $1} 1')" > $R/roots/acnh@live.tmp/.root_pid   # 同 pack/roots.sh _root_owner：pid + 起始时间
( exit 0 ) & dp=$!; wait $dp; echo "$dp x" > $R/roots/acnh@dead.tmp/.root_pid; old 3 $R/roots/acnh@dead.tmp $R/roots/acnh@live.tmp
o=$(S2A_RUN=$R bash $H/tools/gc.sh 2>&1)
ck "⑥ 局目录：超龄未引用 acnh_1_1 删；被记分板引用 acnh_2_1、带 .keep acnh_3_1、1 小时前 acnh_4_1 留" '[ ! -e $J/acnh_1_1 ] && [ -d $J/acnh_2_1 ] && [ -d $J/acnh_3_1 ] && [ -d $J/acnh_4_1 ]'
ck "⑦ 产物根：留现行 c + 上一版 b、删 a；死持有者 .tmp 删、活持有者 .tmp 留" '[ -d $R/roots/acnh@c ] && [ -d $R/roots/acnh@b ] && [ ! -e $R/roots/acnh@a ] && [ ! -e $R/roots/acnh@dead.tmp ] && [ -d $R/roots/acnh@live.tmp ]'
sleep 60 & L8=$!; mkdir -p $R/.gc.lock; echo "$L8 Mon Jan  1 00:00:00 2001" > $R/.gc.lock/pid; o8=$(S2A_RUN=$R bash $H/tools/gc.sh 2>&1)   # 本条自起持有者（⑦ 的 sleep 在慢机上可能已退出）
mkdir -p $R/.gc.lock; echo "$L8 $(ps -o lstart= -p $L8 | awk '{$1 = $1} 1')" > $R/.gc.lock/pid; o8b=$(S2A_RUN=$R bash $H/tools/gc.sh 2>&1); rm -rf $R/.gc.lock
mkdir -p $R/.gc.lock; echo "$L8" > $R/.gc.lock/pid; touch -t 202610200000 $R/.gc.lock; o8c=$(S2A_RUN=$R bash $H/tools/gc.sh 2>&1)   # 旧格式锁（只有 pid）、2 小时前的
mkdir -p $R/.gc.lock; echo "$L8" > $R/.gc.lock/pid; o8d=$(S2A_RUN=$R bash $H/tools/gc.sh 2>&1); rm -rf $R/.gc.lock; kill $L8 2> /dev/null   # 旧格式锁、刚建的
ck "⑧ 旧格式锁（只有 pid、pid 活着）：60 分钟前的当残留接管（$(tail -1 <<< "$o8c" | cut -c1-30)）、刚建的照样跳过（$(tail -1 <<< "$o8d" | cut -c1-30)）" '! grep -q "另一份 gc 在跑" <<< "$o8c" && grep -q "另一份 gc 在跑" <<< "$o8d"'
ck "⑧ gc 锁：pid 活着但起始时间不符 → 照跑（$(tail -1 <<< "$o8" | cut -c1-40)）；起始时间相符 → 跳过（$(tail -1 <<< "$o8b" | cut -c1-40)）" '! grep -q "另一份 gc 在跑" <<< "$o8" && grep -q "另一份 gc 在跑" <<< "$o8b"'
[ $bad = 0 ] && echo "disk_gate 单测全过" || { echo "disk_gate 单测有不通"; echo "$o" | tail -20; exit 1; }
