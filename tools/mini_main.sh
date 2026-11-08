#!/bin/bash
# 合入后钩子：把 main 推到 mini 的常驻裸库（10-23 jhz「跑完合并再同步过去」）。门禁开跑时 mini 已有 main 的全部对象，
#   remote.sh 推分支只传分支相对 main 的那几个提交；不在任何门禁的关键路径上（合入后钩子后台跑）。远端是本机（local）或连不上 → 跳过，退出 0
set -u; cd "${S2A_POST_REPO:-$(dirname "$0")/..}" || exit 0
H=$(bash tools/remote.sh --host 2> /dev/null); case $H in ''|local) echo "mini 常驻 main：没有远端，跳过"; exit 0;; esac
RR=${S2A_REMOTE_ROOT:-.s2arm/remote}; REV=$(git rev-parse "${S2A_POST_REV:-HEAD}^{commit}") || exit 0; s=$SECONDS
if GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=8" timeout 300 git push -q -f "$H:$RR/S2Arm.git" "$REV:refs/heads/main" 2> /dev/null; then
  echo "mini 常驻 main → ${REV:0:9}（$((SECONDS - s)) 秒）"
else echo "【黄】mini 常驻 main 推送没成（${H}，$((SECONDS - s)) 秒）；下次门禁照常整推，不挡"; fi
exit 0
