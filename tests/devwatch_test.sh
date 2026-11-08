#!/bin/bash
# 真机执行器硬上限看门狗单测（tools/devwatch.sh）：bash tests/devwatch_test.sh
# 造 11-04 现场：主进程停在等命令替换读完（bash 推迟 TERM 处理），攥着命令替换输出的子进程忽略 TERM（直接子进程 / 挂到 1 号下的孤儿两种）。
# 期望（手算）：上限 1 秒 + 宽限 2 秒 → 约 3 秒内主进程与攥管道的进程都没了、run.log 与标准输出各一行强杀结论；
#   别的局（输出不是本局管道）的进程不碰；调用方在同一命令替换里的子 shell（主进程祖先）不碰；主进程正常处理 TERM 时不强杀。反证：只发 TERM 的旧看门狗卡满子进程的 30 秒（这里 12 秒判超）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
# $1 场景 direct|orphan|clean，$2 看门狗脚本；主进程把自己 pid 写 $T/<场景>.pid，攥管道的进程写 $T/<场景>.hold
mk() { cat > "$T/main_$1.sh" <<EOF
source "$2"; O=$T/o_$1; mkdir -p "\$O"; echo \$\$ > $T/$1.pid
trap 'echo "TERM 处理" >> "\$O/run.log"; exit 3' TERM
S2A_CAP_GRACE_S=2 arm 1
case $1 in
  direct) x=\$(bash -c 'echo \$\$ > $T/$1.hold; trap "" TERM; exec sleep 30');;
  orphan) x=\$( ( (trap "" TERM; echo \$BASHPID > $T/$1.hold; exec sleep 30) & ) );;
  clean)  sleep 30;;
esac
EOF
}
run() { local s=$SECONDS; timeout -s KILL 12 bash "$T/main_$1.sh" > "$T/$1.out" 2>&1; echo $(( SECONDS - s )) > "$T/$1.secs"; }
alive() { [ -s "$1" ] && kill -0 "$(cat "$1")" 2> /dev/null; }
sleep 60 > $T/decoy.out 2>&1 & DECOY=$!   # 别的局：输出走自己的文件、与本局管道无关，不许被杀
for sc in direct orphan clean; do mk $sc "$H/tools/devwatch.sh"; run $sc; done
# 祖先：调用方 x=$( bash main_direct.sh; echo 祖先还活着 )——祖先子 shell 也握着同一个写端，强杀后它必须还能接着打这一行
mk direct "$H/tools/devwatch.sh"; x=$( timeout -s KILL 12 bash "$T/main_direct.sh" 2>&1; echo 祖先还活着 ); case $x in *祖先还活着*) echo ok > $T/anc.ok;; esac; sleep 1
ck "直接子进程忽略 TERM、主进程等命令替换：约 3 秒内收掉（实为 $(cat $T/direct.secs) 秒），攥管道的子进程已死" '[ "$(cat $T/direct.secs)" -le 8 ] && ! alive $T/direct.hold && ! alive $T/direct.pid'
ck "直接子进程场景：run.log 与标准输出各一行强杀结论" 'grep -q "强杀本局全部进程" $T/o_direct/run.log && grep -q "^RESULT=red out=$T/o_direct reason=硬上限到点后进程不退，强杀" $T/direct.out'
ck "孤儿（挂到 1 号下、pkill -P 够不着）攥着命令替换输出：照样收掉（实为 $(cat $T/orphan.secs) 秒），孤儿已死" '[ "$(cat $T/orphan.secs)" -le 8 ] && ! alive $T/orphan.hold && ! alive $T/orphan.pid'
ck "调用方在同一命令替换里的子 shell（主进程祖先、也握写端）不被误杀" '[ -s $T/anc.ok ]'
ck "主进程正常处理 TERM（sleep 时）：走 TERM 处理、不打强杀行" 'grep -q "TERM 处理" $T/o_clean/run.log && ! grep -q 强杀 $T/o_clean/run.log'
ck "别的局（输出不是本局管道）的进程不碰" 'kill -0 $DECOY 2> /dev/null'
# 反证：只发 TERM 的旧看门狗（main d7f867597 的 arm）同一现场卡到外层 12 秒超时
cat > "$T/old.sh" <<'EOF'
arm() { ( sleep "$1"; kill -TERM $$ 2>/dev/null; pkill -TERM -P $$ 2>/dev/null ) & WD=$!; disown "$WD"; }
EOF
mk direct "$T/old.sh"; run direct
ck "反证：旧看门狗同一现场卡满外层 12 秒（实为 $(cat $T/direct.secs) 秒）" '[ "$(cat $T/direct.secs)" -ge 11 ]'
kill $DECOY 2> /dev/null; for f in $T/*.hold; do alive "$f" && kill -KILL "$(cat "$f")"; done; rm -rf $T
[ $bad = 0 ] && echo "devwatch 单测全过" || { echo "devwatch 单测有不通"; exit 1; }
