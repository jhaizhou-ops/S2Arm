#!/bin/bash
# 同款反复起局单测（tools/mac_repeat.sh，约 1 秒，不起真局）：bash tests/mac_repeat_test.sh
# 假 mac_health（MAC_REPEAT_HEALTH）按局目录名写 host.log（同轮并行，不靠调用先后）：r1a / r1b 有首帧到 MARK，r2a 有首帧且崩，r2b 没首帧但崩。
# 期望按这份剧本直接数：2 轮 × 2 局 → 局 4、有首帧 3、崩 1（没首帧的崩不计）、到 MARK 2、退出 1；
#   -- 之后的变量原样进每一局（含空格的值不被拆）；--stop-on-crash 时第 2 轮有崩 → 停在第 2 轮；剧本全不崩 → 退出 0；不给 --root → 退出 2
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0
ck() { if [ "$2" = "$3" ]; then echo "通 $1：$3"; else echo "不通 $1：期望 $2 → 真结果 $3"; bad=1; fi; }
mkdir -p "$T/root"; : > "$T/root/addr_need.tsv"   # 产物根 = 这一款的目录本身（同 HEALTH_ROOT_<款>）
cat > "$T/fake_health.sh" <<'EOF'
#!/bin/bash
d=$1; g=$2; mkdir -p "$d/$g"
t=$(basename "$d")
root_var=HEALTH_ROOT_$g
{ echo "参数 GAMES=$GAMES PAR=$HEALTH_PAR SEC=$HEALTH_SEC ROOT=${!root_var} FOO=[${FOO:-}]"
  case ${FAKE_PLAN:-mix}:$t in
    mix:r2a) echo "首帧上屏"; echo "[s2a] 【红】CRASH 信号 11";;
    mix:r2b) echo "[s2a] 【红】CRASH 信号 11";;
    *) echo "首帧上屏"; echo "S2A 标记 MARK：帧 4178";;
  esac; } > "$d/$g/host.log"
EOF
run() { MAC_REPEAT_HEALTH=$T/fake_health.sh bash "$H/tools/mac_repeat.sh" "$@"; }

out=$(FAKE_PLAN=mix run "$T/o1" smg2 --root "$T/root" --rounds 2 --par 2 --sec 77 -- FOO="a b" 2>&1); rc=$?
ck "混合剧本 2 轮 × 2 局：汇总行" "mac_repeat：smg2 局 4，有首帧 3，崩 1，到 MARK 2" "$(echo "$out" | tail -1)"
ck "混合剧本：有首帧的局里有崩 → 退出 1" 1 $rc
ck "参数透传（款 / 每局 PAR=1 / 秒数 / 显式产物根 / 含空格的额外变量）" "参数 GAMES=smg2 PAR=1 SEC=77 ROOT=$(cd -P "$T/root" && pwd) FOO=[a b]" "$(head -1 "$T/o1/r1a/smg2/host.log")"
ck "每局一行：到 MARK 的写帧号、没到的写「没到」" "r1a 首帧=1 崩=0 MARK=帧 4178 / r2b 首帧=0 崩=1 MARK=没到" "$(grep '^r1a ' <<< "$out") / $(grep '^r2b ' <<< "$out")"
ck "局目录命名 r<轮><a|b>" "r1a r1b r2a r2b" "$(cd "$T/o1" && ls -d r?? | tr '\n' ' ' | sed 's/ $//')"

out=$(FAKE_PLAN=mix run "$T/o2" smg2 --root "$T/root" --rounds 5 --par 2 --stop-on-crash 2>&1); rc=$?
ck "--stop-on-crash：第 2 轮有崩就停（共 4 局）" "mac_repeat：smg2 局 4，有首帧 3，崩 1，到 MARK 2" "$(echo "$out" | tail -1)"

out=$(FAKE_PLAN=clean run "$T/o3" smg2 --root "$T/root" --rounds 1 --par 3 2>&1); rc=$?
ck "全不崩：1 轮 × 3 局、退出 0" "mac_repeat：smg2 局 3，有首帧 3，崩 0，到 MARK 3 / 0" "$(echo "$out" | tail -1) / $rc"

bash "$H/tools/mac_repeat.sh" "$T/o4" smg2 > /dev/null 2>&1; rc=$?
ck "不给 --root → 退出 2（不走 @现行 刷新）" 2 $rc
mkdir -p "$T/emptyroot"; MAC_REPEAT_HEALTH=$T/fake_health.sh bash "$H/tools/mac_repeat.sh" "$T/o5" smg2 --root "$T/emptyroot" > /dev/null 2>&1; rc=$?
ck "空产物根 → 退出 2" 2 $rc

rm -rf "$T"
[ $bad = 0 ] && echo "mac_repeat：全过" || echo "mac_repeat：有不通"
exit $bad
