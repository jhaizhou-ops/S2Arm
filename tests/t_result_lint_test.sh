#!/bin/bash
# 门禁只看：tools/t_result_lint.py runtime/include/s2a_t_result.h runtime/tests/* graphics/nvn/tests/*
# 单测结论行静态检查（tools/t_result_lint.py；11-07 总指挥：warm-bump、buf-reg-scalable 单测全过、只因没打「✓ t_」被原生门禁判红）。约 2 秒。
# 入队预检自动跑（tests/*lint*_test.sh）：① 本支对 origin/main 改到的 t_*.c|m 真查一遍（入队拦截就是这一条）。夹具期望按规则手写：
#   ② 写成「t_x 全过」（warm-bump 原样，没有 ✓）→ 红、点名文件与写法；③ 字面「✓ t_x」/ S2A_T_RESULT("t_x", bad) / 三元「"✓"」+ t_x / .mk 里 echo「✓ t_x」→ 都不红
#   ④ 共用宏真编真跑：bad=0 打「✓ t_demo：全过」退 0；bad=2 打「✗ t_demo：2 项不通」退 1
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0; trap 'rm -rf "$T"' EXIT
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
o1=$(cd "$H" && python3 tools/t_result_lint.py 2>&1); r1=$?
ck "① 本支改到的单测都有结论行（rc=${r1}；$(tail -1 <<< "$o1")）" '[ $r1 = 0 ]'
mkdir -p "$T/runtime/tests" "$T/graphics/nvn/tests/mk"; cd "$T" || exit 1
printf 'int main(void){int bad=0; printf(bad ? "t_wb 有不通\\n" : "t_wb 全过\\n"); return bad;}\n' > runtime/tests/t_wb.c
printf 'int main(void){puts("✓ t_lit：全过");}\n' > runtime/tests/t_lit.c
printf '#include "s2a_t_result.h"\nint main(void){int bad=0; return S2A_T_RESULT("t_mac", bad);}\n' > runtime/tests/t_mac.c
printf 'int main(void){int bad=0; printf("%%s t_ter：%%d\\n", bad ? "✗" : "✓", bad);}\n' > graphics/nvn/tests/t_ter.m
printf 'int main(void){return 0;}\n' > graphics/nvn/tests/t_mk.m; printf "native-test-mk:\n\t@echo '✓ t_mk：两种模式均通过'\n" > graphics/nvn/tests/mk/t_mk.mk
o2=$(python3 "$H/tools/t_result_lint.py" --files runtime/tests/t_wb.c 2>&1); r2=$?
ck "② warm-bump 原样（没有 ✓）→ 红、点名文件与写法（rc=${r2}）" '[ $r2 = 1 ] && grep -q "runtime/tests/t_wb.c:1: 没有门禁结论行" <<< "$o2" && grep -q "S2A_T_RESULT(\"t_wb\", bad)" <<< "$o2"'
o3=$(python3 "$H/tools/t_result_lint.py" --files runtime/tests/t_lit.c runtime/tests/t_mac.c graphics/nvn/tests/t_ter.m graphics/nvn/tests/t_mk.m 2>&1); r3=$?
ck "③ 字面 / 共用宏 / 三元 / .mk echo 四种写法都不红（rc=${r3}；$(tail -1 <<< "$o3")）" '[ $r3 = 0 ] && grep -q "查 4 个改动单测，0 个没有结论行" <<< "$o3"'
printf '#include "s2a_t_result.h"\n#include <stdlib.h>\nint main(int c, char **v){return S2A_T_RESULT("t_demo", atoi(v[1]));}\n' > d.c
if cc -I"$H/runtime/include" -o d d.c 2> cc.err; then
  a=$(./d 0); ra=$?; b=$(./d 2); rb=$?
  ck "④ 共用宏：0 → 「${a}」退 ${ra}；2 → 「${b}」退 ${rb}" '[ "$a" = "✓ t_demo：全过" ] && [ $ra = 0 ] && [ "$b" = "✗ t_demo：2 项不通" ] && [ $rb = 1 ]'
else ck "④ 共用宏编不过：$(head -1 cc.err)" false; fi
[ $bad = 0 ] && echo "t_result_lint 单测全过"; exit $bad
