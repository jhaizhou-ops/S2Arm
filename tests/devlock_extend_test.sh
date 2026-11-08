#!/bin/bash
# 设备锁续租单测（tools/devlock.sh devlock_extend，不碰手机，约 7 秒）：bash tests/devlock_extend_test.sh
# 期望：两个持锁者都以上限 3 秒取锁——续到 60 秒的那个看门狗不动它；不续的那个被看门狗终止（对照，证明看门狗在管）
#   10-21 晚巫师3 整包重推 1089 秒：dev_run 把部署段放大到 3452 秒，取锁时给的 1200 秒没跟着放大，游戏起来不到 1 分钟被停
#   按事件判、不跟看门狗赛跑（11-05 合入运维线根修：原先两边各占 7 秒、看门狗每 2 秒一醒，余量约 3 秒靠墙钟比赛；11-02 本机补跑红过一次，
#   两条判据合在一起、stderr 丢进 /dev/null，看不出哪一半不通）：
#   不续：一直持有，只有被看门狗终止才结束（60 秒只防挂、到点写「防挂到点」）→ 退出码 143（TERM）、看门狗日志「超过上限 3 秒」
#   续：持有到「对照那份的看门狗已动手（raw.wd 出现超过上限）」且自己已持有 ≥ 6 秒（越过原上限 3 秒、看门狗 2 秒一轮）才放；没被终止、自己的看门狗日志为空
export SW_DEVBATTERY=0 DEVBATTERY_DIR=$(mktemp -d)
set -u; H=$(cd "$(dirname "$0")/../tools" && pwd); T=$(mktemp -d); bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
# 持锁者用独立 bash 进程（devlock 按 $$ 认持锁者、看门狗终止它的进程树；子 shell 的 $$ 是本单测，会把单测自己杀掉）；stdout / stderr 留在 $T/<名>.err
hold() { SW_DEVLOCK_DIR=$T/$1.lock SW_DEVLOCK_QUEUE=$T/$1.queue SW_DEVLOCK_WD_LOG=$T/$1.wd bash -c "unset SW_DEVLOCK_HELD; source $H/devlock.sh; devlock_acquire '单测 $1' 3 || exit 1
  hd() { echo \$(( \$(date +%s) - \$(cat $T/$1.lock/started) )); }; n=0
  if [ '$2' = 续 ]; then devlock_extend 60 || { echo 续租失败 > $T/$1.done; exit 1; }
    until grep -q 超过上限 $T/raw.wd 2> /dev/null && [ \$(hd) -ge 6 ]; do [ \$n -ge 600 ] && { echo \"防挂到点 \$(hd)\" > $T/$1.done; exit 1; }; sleep 0.1; n=\$((n + 1)); done
    echo \"撑满 \$(hd)\" > $T/$1.done
  else while [ \$n -lt 600 ]; do sleep 0.1; n=\$((n + 1)); done; echo \"防挂到点 \$(hd)\" > $T/$1.done; fi
  devlock_release" > $T/$1.err 2>&1 & }
hold ext 续; pe=$!; hold raw 不续; pr=$!; wait $pr; rr=$?; wait $pe; re=$?
er() { tr '\n' ' ' < $T/$1.err 2> /dev/null | cut -c1-400; }
ck "不续的持锁者（上限 3 秒）被看门狗终止：退出码 143、日志「超过上限 3 秒」、没撑到防挂（退出码 ${rr}；$(cat $T/raw.done 2> /dev/null)；stderr「$(er raw)」）" '[ "$rr" = 143 ] && [ ! -e $T/raw.done ] && grep -q "超过上限 3 秒" $T/raw.wd'
ck "续到 60 秒的持锁者：对照的看门狗动手后自己持有 ≥ 6 秒才放、没被终止（退出码 ${re}；$(cat $T/ext.done 2> /dev/null)；stderr「$(er ext)」）" '[ "$re" = 0 ] && grep -q "^撑满 " $T/ext.done && ! grep -q 看门狗 $T/ext.wd 2> /dev/null'
rm -rf $T "$DEVBATTERY_DIR"; [ $bad = 0 ] && echo "devlock_extend 单测全过" || { echo "devlock_extend 单测有不通"; exit 1; }
