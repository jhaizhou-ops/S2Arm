#!/bin/bash
# RomFS 存储清扫与并行提交的交错（审计 #1508 P1-108，pack/roots.sh root_commit / root_romfs_sweep）单测：临时目录，秒级。bash tests/roots_romfs_sweep_race_test.sh
# 交错按事件制造、不赌墙钟：清扫刚读完现行的 romfs 链接（名单已拍下、还没删）时放行界面布局阶段 B（声明 romfs）去提交，
#   再等 B 发出两个事件之一：「已把新身份收进存储」或「拿提交锁被挡」，清扫才往下走。
# 期望按规则手写（不复述实现）：
#   一、提交里的清扫（改写阶段 A 的 root_commit）：清扫与收纳同一把提交锁串行 → B 一定被锁挡；B 提交后现行 romfs 指向的新身份还在、内容是 B 写的
#   二、不持锁的清扫（tools/gc.sh 的 root_romfs_sweep）：删前再读一次链接 → B 在名单之后收纳的新身份照样留着
#   两种都要：没有任何版本指向的旧身份照样删（不放宽「没人指向就删」）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
source "$H/tools/plock.sh"
waitev() { local i e; for i in $(seq 1 600); do for e in "$@"; do [ -e "$EV/$e" ] && return 0; done; sleep 0.05; done; echo "【红】等事件 $* 超时" >&2; return 1; }
# 清扫读完现行的 romfs 链接时放行 B，等 B 收纳完或被锁挡住再往下（布防后只触发一次）
readlink() {
  command readlink "$@"; local rc=$?
  if [[ " ${FUNCNAME[*]} " == *" root_romfs_sweep "* ]] && [[ "$*" == *@现行/romfs ]] && [ -e $EV/armed ] && mkdir $EV/fired 2> /dev/null; then touch $EV/go; waitev interned blocked >&2; fi
  return $rc
}
# run <名> <commit|gc>：播种 → A、B 同一现行开工 → B 等放行 → 清扫（A 提交里的，或 gc 式单独调）中途放行 B
run() {
  local n=$1 how=$2 A B W BP c d v
  export S2A_ROOTS=$T/$n/roots S2A_ROOTS_SHARED=$T/shared S2A_ROOTS_PRIV=$T/priv; EV=$T/$n/ev; mkdir -p $EV; source "$H/pack/roots.sh"
  W=$(root_begin g s0) && mkdir -p $W/romfs/Layout && echo lyt > $W/romfs/Layout/x.bflyt && root_commit g s0
  A=$(root_begin g rw1); echo rw > $A/rw.txt
  B=$(ROOT_OWN_ROMFS=1 root_begin g ui1); rm -f $B/romfs/Layout/x.bflyt && echo wide > $B/romfs/Layout/x.bflyt
  (
    eval "_real_plock_take() $(declare -f plock_take | tail -n +2)"
    plock_take() { _real_plock_take "$1" 0 && return 0; touch $EV/blocked; _real_plock_take "$@"; }
    eval "_real_intern() $(declare -f _root_romfs_intern | tail -n +2)"
    _root_romfs_intern() { _real_intern "$@" || return 1; touch $EV/interned; }
    waitev go && ROOT_REPLAY='romfs' root_commit g ui1 2> $T/$n/b.err; echo $? > $EV/b.rc
  ) & BP=$!
  if [ $how = commit ]; then touch $EV/armed; ROOT_REPLAY='rw.txt' root_commit g rw1 2> $T/$n/a.err; ARC=$?
  else ROOT_REPLAY='rw.txt' root_commit g rw1 2> $T/$n/a.err; ARC=$?; mkdir -p $T/$n/roots/.romfs_store/g/orphan; touch $EV/armed; root_romfs_sweep g 2> /dev/null; fi
  wait $BP; BRC=$(cat $EV/b.rc 2> /dev/null)
  C=$(root_cur g); L=$(command readlink $C/romfs 2> /dev/null); D=$S2A_ROOTS/.romfs_store/g/${L##*/}
  EVS=$( [ -e $EV/blocked ] && echo B被锁挡 || { [ -e $EV/interned ] && echo B在清扫中收纳; } )
  OK=0; [ "$(basename $C)" = g@ui1 ] && [ -d "$D" ] && [ "$(cat $C/romfs/Layout/x.bflyt 2> /dev/null)" = wide ] && OK=1
  for c in s2 s3; do W=$(root_begin g $c) && root_commit g $c 2> /dev/null; done
  ORPH=0; for d in $S2A_ROOTS/.romfs_store/g/*; do grep -qxF "../.romfs_store/g/${d##*/}" <<< "$(for v in $S2A_ROOTS/g@*; do [ -L $v/romfs ] && command readlink $v/romfs; done)" || ORPH=$((ORPH + 1)); done
  RD=$(cat $(root_cur g)/romfs/Layout/x.bflyt 2> /dev/null)
}
# 一、提交里的清扫（A 先拿锁提交，清扫中途 B 来提交）
run c1 commit
ck "提交里的清扫：交错已制造（${EVS:-没触发}）、两笔都成功（A rc=${ARC}，B rc=${BRC:-无}）" '[ -e $EV/fired ] && [ -n "$EVS" ] && [ $ARC = 0 ] && [ "${BRC:-1}" = 0 ]'
ck "提交里的清扫与收纳同一把提交锁串行：B 被锁挡（实际：${EVS:-没触发}）" '[ "$EVS" = B被锁挡 ]'
ck "提交里的清扫：现行 = ui1，romfs 指向的新身份（${L:-无链接}）还在、内容 wide" '[ $OK = 1 ]'
ck "提交里的清扫：之后再提交两笔，无主身份 ${ORPH} 个、现行 romfs 可读（${RD:-读不到}）" '[ $ORPH = 0 ] && [ "$RD" = wide ]'
# 二、不持锁的清扫（gc 式）：A 提交完之后单独清扫，存储里另放一个无主身份 orphan；清扫中途 B 来提交（B 拿得到锁）
run c2 gc
ck "不持锁的清扫：交错已制造（${EVS:-没触发}）、B 在清扫中收纳、两笔都成功（A rc=${ARC}，B rc=${BRC:-无}）" '[ -e $EV/fired ] && [ "$EVS" = B在清扫中收纳 ] && [ $ARC = 0 ] && [ "${BRC:-1}" = 0 ]'
ck "不持锁的清扫：删前再读链接，名单之后收纳的新身份（${L:-无链接}）还在、内容 wide" '[ $OK = 1 ]'
ck "不持锁的清扫：无主的 orphan 照样删、之后无主身份 ${ORPH} 个、现行 romfs 可读（${RD:-读不到}）" '[ ! -e $T/c2/roots/.romfs_store/g/orphan ] && [ $ORPH = 0 ] && [ "$RD" = wide ]'
chmod -R u+w $T 2> /dev/null; rm -rf $T; [ $bad = 0 ] && echo "RomFS 清扫并行提交单测全过" || { echo "RomFS 清扫并行提交单测有不通"; exit 1; }
