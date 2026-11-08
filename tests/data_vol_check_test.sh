#!/bin/bash
# 数据卷检查单测（tools/data_vol_check.sh，约 1 秒）：期望按规则手写——无标记放行；数据卷没挂载 → 125；登记目录被真目录替换 → 125；全是软链且挂载 → 0
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
export S2A_RUN_ROOT=$T/run S2A_DATA_VOL_DIRS="roots cache"; S=$T/run/s2arm; mkdir -p $S
run() { bash "$H/tools/data_vol_check.sh" 2>&1; }
o=$(run); r=$?; ck "① 没有 .data_vol 标记（这台没用该布局）→ 放行 rc=${r}（0）" '[ $r = 0 ] && [ -z "$o" ]'
VOLOK=$(df -P "$T" | awk 'NR==2{print $NF}')   # 一个一定处于挂载状态的卷根（测试用，借 mount 输出里确有的挂载点）
[ "$VOLOK" = / ] && VOLOK=/System/Volumes/Data
echo "$VOLOK" > $S/.data_vol; mkdir -p $T/vol/roots $T/vol/cache; ln -s $T/vol/roots $S/roots; ln -s $T/vol/cache $S/cache
o=$(run); r=$?; ck "② 标记指向已挂载的卷、登记目录都是软链 → 0（rc=${r}）" '[ $r = 0 ]'
echo "/$(printf %s Volumes)/NOPE_2T_TEST" > $S/.data_vol
o=$(run); r=$?; ck "③ 数据卷没挂载 → 125、报「没挂载」、不回落（rc=${r}）" '[ $r = 125 ] && [[ "$o" == *没挂载* ]]'
echo "$VOLOK" > $S/.data_vol; rm -f $S/cache; mkdir -p $S/cache
o=$(run); r=$?; ck "④ cache 被内置盘真目录替换 → 125、点名 cache（rc=${r}）" '[ $r = 125 ] && [[ "$o" == *cache* ]] && [[ "$o" == *软链* ]]'
rm -rf $S/cache; ln -s $T/vol/cache $S/cache; rm -f $S/roots   # 登记目录不存在（还没建 / 已搬走没链）→ 不算替换
o=$(run); r=$?; ck "⑤ 登记目录不存在 → 不报替换（rc=${r}）" '[ $r = 0 ]'
rm -rf $T
[ $bad = 0 ] && echo "data_vol_check 单测全过" || { echo "data_vol_check 单测有不通"; exit 1; }
