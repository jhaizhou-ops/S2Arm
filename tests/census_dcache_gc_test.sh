#!/bin/bash
# 普查直连缓存总量上限（tools/census/dcache_gc.py，11-01）：超上限按最久没用的款淘汰，在用的、本次要用的不淘汰，删除走 S2A_SAFE_RM、写 gc.log。约 1 秒
# 期望值按造的数据手算：4 款各写 4 MiB（实占 ≥ 4 MiB），最近用时刻 a < b < c < d；上限 9 MiB、本次用 d、b 在用（另一进程持 store/.inuse 共享锁）
#   → 按 a、b、c 顺序看：a 删（剩 b c d 约 12 MiB > 9）、b 在用跳过、c 删（剩 b d 约 8 MiB ≤ 9）停；d 是本次的款，从不删
#   → 剩 b、d；gc.log 两行（a、c）；删除都经假 safe_rm（记下参数）
# 门禁输入：tools/census/dcache_gc.py tests/census_dcache_gc_test.sh
set -u; H=$(cd "$(dirname "$0")/.." && pwd); PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}; [ -x "$PY" ] || PY=python3
T=$(mktemp -d "${TMPDIR:-/tmp}/s2a-dcache-XXXXXX"); trap 'kill $HP 2> /dev/null; rm -rf "$T"' EXIT; R=$T/root; bad=0
ck() { if [ "$1" = "$2" ]; then echo "通 $3：期望 $2 → 真结果 $1"; else echo "不通 $3：期望 $2 → 真结果 $1"; bad=$((bad + 1)); fi; }
i=0; for k in a b c d; do i=$((i + 1)); mkdir -p "$R/$k/store"; head -c 4194304 /dev/urandom > "$R/$k/store/00.pack"; : > "$R/$k/store/.inuse"; : > "$R/$k/.used"; touch -t "20261101100$i" "$R/$k/.used"; done
"$PY" -c "import fcntl,time,sys; f=open(sys.argv[1],'a'); fcntl.flock(f,fcntl.LOCK_SH); time.sleep(30)" "$R/b/store/.inuse" & HP=$!
for n in $(seq 1 50); do "$PY" -c "import fcntl,sys; f=open(sys.argv[1],'a'); fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)" "$R/b/store/.inuse" 2> /dev/null || break; sleep 0.1; done
printf '#!/bin/bash\necho "$@" >> %s/rm.log; rm -rf "$@"\n' "$T" > "$T/fake_rm.sh"
out=$(S2A_SAFE_RM=$T/fake_rm.sh "$PY" "$H/tools/census/dcache_gc.py" "$R" "$(python3 -c 'print(9/1024)')" d)
ck "$(cd "$R" && ls -d */ | tr -d / | tr '\n' ' ')" "b d " "剩下的款"
ck "$(wc -l < "$R/gc.log" | tr -d ' ')" "2" "gc.log 行数"
ck "$(sed 's#.*/##' "$T/rm.log" | tr '\n' ' ')" "a c " "删除都经 S2A_SAFE_RM、顺序 a c"
ck "$(echo "$out" | grep -c '淘汰')" "2" "标准输出打淘汰行"
# ② 出库在用（11-02）：款 x 最久没用但下面有 work.stage.<活着的进程号>（本测试 shell），y 次之、下面是 mac.stage.<已退出的进程号>，z 本次用；上限 5 MiB
#   → x 在用跳过、y 删（剩 x z 约 8 MiB 仍 > 5，但再没可删的）；剩 x、z
R2=$T/root2; i=0; for k in x y z; do i=$((i + 1)); mkdir -p "$R2/$k/store"; head -c 4194304 /dev/urandom > "$R2/$k/store/00.pack"; : > "$R2/$k/.used"; touch -t "20261101100$i" "$R2/$k/.used"; done
( exit 0 ) & DP=$!; wait $DP
mkdir -p "$R2/x/work.stage.$$" "$R2/y/mac.stage.$DP"
S2A_SAFE_RM=$T/fake_rm.sh "$PY" "$H/tools/census/dcache_gc.py" "$R2" "$(python3 -c 'print(5/1024)')" z > /dev/null
ck "$(cd "$R2" && ls -d */ | tr -d / | tr '\n' ' ')" "x z " "出库进程活着的款不淘汰、已退出的照常淘汰"
echo "普查直连缓存上限单测：$([ $bad = 0 ] && echo 全通 || echo "$bad 项不通")"; exit $(( bad > 0 ))
