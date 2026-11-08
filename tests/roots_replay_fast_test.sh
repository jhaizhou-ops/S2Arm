#!/bin/bash
# 产物根重放 / 修剪不再逐文件搬整根（11-05 一次成功线：时之笛资源包 18.7 万文件，出包收尾在提交锁里删 / 拷 2–3 遍）：bash tests/roots_replay_fast_test.sh（约 3 秒）
# 门禁覆盖：pack/roots.sh tools/gc.sh
# 期望（按规则手写，不跑实现推）：
#   ① 出包阶段开工后别的阶段提交了新现行（x/new 出现）→ ROOT_REPLAY="pkg" 提交：结果有新现行的 x/new、有本阶段 W 改过的 pkg/pack/a、
#      pkg/pack/b 的 inode 与 W 里那份相同（整个挪过来，不是逐文件克隆 / 拷贝出的新文件）
#   ② 修剪：提交后被取代的最旧版本立即不在原位置（挪进 .trash），10 秒内 .trash 清空
#   ③ gc：.trash 里名字带已死 pid 的残余被删，带活 pid 的跳过
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); T=$(cd "$T" && pwd -P); trap 'chmod -R u+w "$T" 2> /dev/null; rm -rf "$T"' EXIT; bad=0
ck() { if [ "$2" = "$3" ]; then echo "通 $1"; else echo "不通 $1：期望「$2」真结果「$3」"; bad=1; fi; }
ino() { stat -f %i "$1" 2> /dev/null || stat -c %i "$1"; }
export S2A_ROOTS=$T/roots S2A_ROOTS_SHARED=$T/shared S2A_ROOTS_NO_BOOT=1; mkdir -p "$S2A_ROOTS"
. "$H/pack/roots.sh"
mkdir -p "$S2A_ROOTS/g@v0/pkg/pack" "$S2A_ROOTS/g@v0/x"; echo a0 > "$S2A_ROOTS/g@v0/pkg/pack/a"; echo b0 > "$S2A_ROOTS/g@v0/pkg/pack/b"; echo old > "$S2A_ROOTS/g@v0/x/old"
ln -s g@v0 "$S2A_ROOTS/g@现行"
W=$(root_begin g p1) || { echo "不通 root_begin"; exit 1; }   # 出包阶段开工
echo a1 > "$W/pkg/pack/a"; ib=$(ino "$W/pkg/pack/b")
W2=$(root_begin g s1) && echo new > "$W2/x/new" && root_commit g s1 2> /dev/null   # 并行的别的阶段先提交
ROOT_REPLAY="pkg" root_commit g p1 2> /dev/null; C=$(cd -P "$S2A_ROOTS/g@现行" && pwd)
ck "① 重放结果：现行 g@p1、有新现行的 x/new、pkg/pack/a 是本阶段的、pkg/pack/b 是同一个 inode（挪过来）" "g@p1 new a1 $ib" \
   "$(basename "$C") $(cat "$C/x/new" 2> /dev/null) $(cat "$C/pkg/pack/a" 2> /dev/null) $(ino "$C/pkg/pack/b")"
ck "① 没留下 .tmp / .rb" "0" "$(ls -a "$S2A_ROOTS" | grep -c '\.tmp\|\.rb')"
# ② 再提交一版：只留现行 + 上一版，最旧的 g@v0 立即不在原位置，10 秒内 .trash 清空
W=$(root_begin g p2) && root_commit g p2 2> /dev/null
ck "② 修剪后原位置只剩上一版 + 现行（v0、s1 不在）" "g@p1 g@p2 " "$(ls "$S2A_ROOTS" | grep -v '^\.' | grep -v 现行 | tr '\n' ' ')"
for i in $(seq 1 50); do [ -z "$(ls -A "$S2A_ROOTS/.trash" 2> /dev/null)" ] && break; sleep 0.2; done
ck "② .trash 后台删空" "" "$(ls -A "$S2A_ROOTS/.trash" 2> /dev/null)"
# ③ gc 清 .trash 残余：死 pid 的删，活 pid 的跳过
S=$T/run; mkdir -p "$S/roots/.trash/g@x.999999.1/d" "$S/roots/.trash/g@y.$$.2"; touch "$S/roots/.trash/g@x.999999.1/d/f"
S2A_RUN=$S S2A_RUN_ROOT=$T bash "$H/tools/gc.sh" --versions > "$T/gc.out" 2>&1
ck "③ gc：死 pid 残余删、活 pid 留" "no yes" "$([ -e "$S/roots/.trash/g@x.999999.1" ] && echo yes || echo no) $([ -e "$S/roots/.trash/g@y.$$.2" ] && echo yes || echo no)"
[ $bad = 0 ] && echo "roots_replay_fast 单测全过" || { echo "roots_replay_fast 单测有不通"; exit 1; }
