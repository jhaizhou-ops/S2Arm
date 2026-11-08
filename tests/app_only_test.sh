#!/bin/bash
# 只换 App 程序快道单测（tools/app_only.sh；临时调度目录 / 产物根，算键与出 ipa 换桩，约 2 秒）：bash tests/app_only_test.sh
#   期望（按快道规则手写）：阶段键全等、着色器只有收集数据段不同 → 出包（新 ipa + 登记包的资源包原样克隆 + app_only.txt）、退出 0；
#   改写键不同 / 着色器代码段不同 → 退出 3 且写明哪段；没有基底产物根 → 退出 2；分支提交带 --register → 拒绝（退出 1）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0; trap 'rm -rf "$T"' EXIT
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
export S2A_SCHED_DIR=$T/sched S2A_ROOTS_SHARED=$T/roots S2A_APP_ONLY_DIR=$T/ao; mkdir -p $T/sched/pkgs $T/roots/acnh@pkg-base1 $T/snap/pack
echo 旧程序 > $T/snap/acnh.ipa; echo 资源 > $T/snap/pack/r.bin; printf 'COMMIT=base1\nPKG=%q\n' "$T/snap" > $T/sched/pkgs/acnh.env
for s in rewrite uilayout aoc romfsidx; do echo k_$s > $T/roots/acnh@pkg-base1/.stage_$s; done; echo 'code1-rgAAA-puBBB' > $T/roots/acnh@pkg-base1/.stage_shaders
printf '#!/bin/bash\nmkdir -p "$S2A_APP_ONLY_OUT"; echo 新程序 > "$S2A_APP_ONLY_OUT/$1.ipa"; : > "$S2A_APP_ONLY_OUT/timing.tsv"; : > "$S2A_APP_ONLY_OUT/build.log"; echo "🟢 $1 只出程序（桩）"\n' > $T/ipa; chmod +x $T/ipa
keys() { printf '#!/bin/bash\nB=$2; for s in rewrite uilayout aoc romfsidx shaders; do v=$(cat "$B/.stage_$s"); %s; printf "%%s\\t%%s\\t%%s\\n" $s "$v" "$(cat "$B/.stage_$s")"; done\n' "$1" > $T/keys; chmod +x $T/keys; }
run() { S2A_APP_ONLY_KEYS=$T/keys S2A_APP_ONLY_IPA=$T/ipa bash $H/tools/app_only.sh acnh "$@" 2>&1; }
keys '[ $s = shaders ] && v=code1-rgNEW-puNEW'; o=$(run); r=$?; C=$(git -C $H rev-parse --short=9 HEAD)
ck "键全等、着色器只有收集数据段变 → 出包（rc=${r}）：新 ipa、资源包是登记包原样、写明沿用 base1" '[ $r = 0 ] && [ "$(cat $T/ao/acnh-$C/pkg/acnh.ipa)" = 新程序 ] && [ "$(cat $T/ao/acnh-$C/pkg/pack/r.bin)" = 资源 ] && grep -q "沿用登记包 base1" $T/ao/acnh-$C/pkg/app_only.txt && [ "$(cat $T/snap/acnh.ipa)" = 旧程序 ]'
keys '[ $s = rewrite ] && v=k_new'; o=$(run); r=$?
ck "改写键变了 → 退出 3（rc=${r}）、写明 rewrite" '[ $r = 3 ] && grep -q "rewrite（k_new" <<< "$o"'
keys '[ $s = shaders ] && v=code2-rgAAA-puBBB'; o=$(run); r=$?
ck "着色器代码段变了 → 退出 3（rc=${r}）、写明着色器代码段" '[ $r = 3 ] && grep -q "着色器（代码段 code2" <<< "$o"'
keys ':'; mv $T/roots/acnh@pkg-base1 $T/roots/x; o=$(run); r=$?; mv $T/roots/x $T/roots/acnh@pkg-base1
ck "登记包的产物根不在 → 退出 2（rc=${r}）" '[ $r = 2 ]'
o=$(run --register); r=$?
if git -C $H merge-base --is-ancestor HEAD origin/main 2> /dev/null; then echo "跳过 分支提交拒绝登记（本树 HEAD 就在 origin/main 上）"
else ck "分支提交带 --register → 拒绝登记（rc=${r}）" '[ $r = 1 ] && grep -q "不许登记成正式包" <<< "$o"'; fi
[ $bad = 0 ] && echo "app_only 单测全过" || { echo "app_only 单测有不通"; exit 1; }
