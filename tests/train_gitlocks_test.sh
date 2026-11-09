#!/bin/bash
# 列车启动清陈旧 git 锁单测（tools/train.sh gitlocks；临时仓库，不碰真仓库，约 1 秒）：bash tests/train_gitlocks_test.sh
# 期望（按规则手写）：开机时刻设为「现在 − 100 秒」；
#   ① 没有 git 进程：早于开机的 .git/config.lock、.git/refs/remotes/origin/x.lock 删掉、各报一行；开机后才出现的 .git/worktrees/w/index.lock 留着
#   ② 有 git 进程在跑：一个都不删，报「本次不清」
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
TR=${S2A_PRIVATE_TOOLS:+$S2A_PRIVATE_TOOLS/train.sh}; TR=${TR:-$H/tools/train.sh}
if [ ! -f "$TR" ]; then echo "train_gitlocks 单测跳过：公开检出没有列车脚本"; exit 75; fi
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
mk() { rm -rf $T/r; git init -q $T/r; mkdir -p $T/r/.git/refs/remotes/origin $T/r/.git/worktrees/w
  : > $T/r/.git/config.lock; : > $T/r/.git/refs/remotes/origin/x.lock; : > $T/r/.git/worktrees/w/index.lock
  touch -t 202601010000 $T/r/.git/config.lock $T/r/.git/refs/remotes/origin/x.lock; }   # 前两个早于开机，index.lock 是现在
BT=$(( $(date +%s) - 100 )); mkdir -p $T/td
mk; o=$(S2A_REPO=$T/r S2A_TRAIN_DIR=$T/td S2A_BOOTTIME=$BT S2A_GITLOCK_PS=false bash $TR gitlocks 2>&1)
ck "① 没有 git 进程：早于开机的两个删、开机后的留（输出「$(tr '\n' '|' <<< "$o")」）" \
  '[ ! -e $T/r/.git/config.lock ] && [ ! -e $T/r/.git/refs/remotes/origin/x.lock ] && [ -e $T/r/.git/worktrees/w/index.lock ] && [ "$(grep -c "清陈旧 git 锁（早于本次开机" <<< "$o")" = 2 ] && grep -q "共清 2 个" <<< "$o"'
mk; o=$(S2A_REPO=$T/r S2A_TRAIN_DIR=$T/td S2A_BOOTTIME=$BT S2A_GITLOCK_PS=true bash $TR gitlocks 2>&1)
ck "② 有 git 进程在跑：一个都不删（输出「$(tr '\n' '|' <<< "$o")」）" \
  '[ -e $T/r/.git/config.lock ] && [ -e $T/r/.git/refs/remotes/origin/x.lock ] && [ -e $T/r/.git/worktrees/w/index.lock ] && grep -q "本次不清" <<< "$o"'
# ③ 真开机时刻解析（不注入 S2A_BOOTTIME）：取到的秒数在「一年前 … 现在」之间（10-29 首版误抓 usec，得 1970 年的 6 位数）
mk; o=$(S2A_REPO=$T/r S2A_TRAIN_DIR=$T/td S2A_GITLOCK_PS=false bash $TR gitlocks 2>&1); bt=$(sysctl -n kern.boottime | sed -n 's/^{ sec = \([0-9]*\),.*/\1/p')
ck "③ 真开机时刻 ${bt}（$(date -r "${bt:-0}" '+%m-%d %T')）合理，早于开机的锁照样清（输出「$(head -1 <<< "$o")」）" \
  '[ "${bt:-0}" -gt $(( $(date +%s) - 31536000 )) ] && [ "$bt" -le "$(date +%s)" ] && [ ! -e $T/r/.git/config.lock ]'
[ $bad = 0 ] && echo "train_gitlocks 单测全过" || { echo "train_gitlocks 单测有不通"; exit 1; }
