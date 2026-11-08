#!/bin/bash
# 门禁覆盖：tools/gc.sh pack/shell/closure.py tests/gc_noread_test.sh
# 工作树回收判定不读树内容（11-07 启动器线：出壳闭包判黄 10713/10715——gc 周期扫 ~/.s2arm/wt 时对出壳中途的树跑 git status，
#   mark 已改了全部文件的状态时间，git 整树重读，闭包当成出壳读到）。期望手写：mark 后跑 gc 的 wt_gcable，被读文件 0 个
#   ① 闲置树（全部文件修改时间 3 小时前）：照常走到 git status 判定，但不读内容 ② 刚写过的树（出壳 / 编译中）：只看修改时间就跳过
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0; trap 'rm -rf "$T"' EXIT
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
GC=${1:-$H/tools/gc.sh}   # 单测自核用：传旧版 gc.sh 应当不通
eval "$(sed -n '/^wt_gcable() {/,/return 0; }$/p' "$GC")"
mk() { local r=$T/$1; mkdir -p $r/src; for i in 1 2 3 4 5 6; do echo "f$i" > $r/src/f$i.c; done; echo m > $r/Makefile
  git -C $r init -q && git -C $r add -A && git -C $r -c user.email=t@t -c user.name=t commit -qm init; echo $r; }
old() { find "$1" -exec touch -m -h -t "$(date -v-${2:-3}H +%Y%m%d%H%M)" {} + 2> /dev/null; }   # 只改修改时间（-m）：mark 设旧的访问时间不能动
a=$(mk idle); old $a; python3 "$H/pack/shell/closure.py" mark $a > /dev/null; old $a/.git 2   # 先设旧再 mark（索引记下旧修改时间）；mark 刷索引使 .git 变新，把 .git 设成 2 小时前（仍闲、但比文件新，不 racy），判定才走到 git status
why=$(wt_gcable $a 60); o=$(python3 "$H/pack/shell/closure.py" observed $a)
ck "① 闲置树：mark 后跑判定（走到 git status：${why:0:40}），被读 $(printf '%s' "$o" | grep -c .) 个文件" '[ -z "$o" ]'
b=$(mk busy); python3 "$H/pack/shell/closure.py" mark $b > /dev/null; touch $b/src/f1.c.o
why=$(wt_gcable $b 60); o=$(python3 "$H/pack/shell/closure.py" observed $b)
ck "② 出壳中的树：判「${why}」，被读 $(printf '%s' "$o" | grep -c .) 个文件" '[ -z "$o" ] && [[ "$why" == *"分钟内有改动"* ]]'
[ $bad = 0 ] && echo "gc_noread 单测全过" || { echo "gc_noread 单测有不通"; exit 1; }
