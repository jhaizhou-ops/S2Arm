#!/bin/bash
# 分片清单不经命令行参数（10-24 #100 奥德赛 12572 片：ls 通配参数超 ARG_MAX，清单 0 字节、出包照绿）。
# 造片数够多、路径够长的目录，使「ls 通配」参数总长超过 ARG_MAX：
#   ① 反证：旧写法 ls "$D"/pso.*.mtl4-json 失败（退出非 0、输出 0 行）
#   ② pso_dist.sh list 列全（行数 = 片数），按 C 区域排序
#   ③ run 给了应有片数而清单行数不符 → 退出 1、报红；清单空而应有 0 片 → 退出 0（暗黑3：程序 0 不是失败）
set -u
H=$(cd "$(dirname "$0")/.." && pwd); PD=$H/pso_dist.sh
fail=0; ck() { if eval "$1"; then echo "  ✓ $2"; else echo "  ✗ $2"; fail=$((fail + 1)); fi; }
T=$(mktemp -d "${TMPDIR:-/tmp}/t_pso_list.XXXXXX"); trap 'rm -rf "$T"' EXIT
AM=$(getconf ARG_MAX)
D=$T/$(printf 'd%.0s' $(seq 1 120))   # 长目录名：每个参数都带它
mkdir -p "$D"
N=$(( AM / (${#D} + 24) + 500 ))       # 参数总长 ≈ N ×（目录长 + 文件名长）> ARG_MAX
( cd "$D" && i=0; while [ $i -lt $N ]; do : > "pso.$i.mtl4-json"; i=$((i + 1)); done )
echo "· 片数 ${N}，目录长 ${#D}，ARG_MAX ${AM}（参数约 $(( N * (${#D} + 24) )) 字节）"
ls "$D"/pso.*.mtl4-json > "$T/old.txt" 2> /dev/null; orc=$?
ck '[ "$orc" != 0 ] && [ ! -s "$T/old.txt" ]' "① 旧写法 ls 通配失败（退出 ${orc}、输出 $(grep -c . "$T/old.txt") 行）"
bash "$PD" list "$D" "$T/list.txt"; lrc=$?
nl=$(grep -c . "$T/list.txt")
ck '[ "$lrc" = 0 ] && [ "$nl" = "$N" ]' "② list 列全：退出 ${lrc}、${nl} 行（应 ${N}）"
ck '[ "$(LC_ALL=C sort "$T/list.txt" | cmp - "$T/list.txt" && echo y)" = y ] && [ "$(head -1 "$T/list.txt")" = "$D/pso.0.mtl4-json" ]' '② 清单按 C 区域排序、路径带目录'
: > "$T/empty.txt"
out=$(bash "$PD" run "$T/empty.txt" "$N" 2>&1); rrc=$?
ck '[ "$rrc" = 1 ] && echo "$out" | grep -q "🔴 分片清单"' "③ 空清单而应有 ${N} 片 → 退出 ${rrc}、报红"
out=$(bash "$PD" run "$T/empty.txt" 0 2>&1); zrc=$?
ck '[ "$zrc" = 0 ]' "③ 空清单而应有 0 片 → 退出 ${zrc}（没有分片不是失败）"
echo "t_pso_list：$((5 - fail)) / 5 项$([ $fail = 0 ] && echo 通过 || echo 失败)"
exit $fail
