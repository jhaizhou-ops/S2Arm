#!/bin/bash
# 出包时自动出宽屏表的挂点（画幅线，10-24）：graphics/widen/scan/auto_kick.sh <款>（pack/ipa.sh、pack/oneclick/oneclick.sh 刷完产物根后调）
#   现行产物根这一构建号、掌机 / 主机两档（S2A_LOOP_MODE 给了只出那一档）各自既没仓库表也没自动表结论 → 后台起 auto_table.sh，本次出包不等；立即返回 0。
#   S2A_WIDEN_AUTO_RUN=0 关（如只想复现某个包、不想占 Mac）。已有结论 / 已在跑由 auto_table.sh 自己判（锁 + status），这里不重复判。
G=${1:?款}; H=$(cd "$(dirname "$0")" && pwd)
[ "${S2A_WIDEN_AUTO_RUN:-1}" = 0 ] && exit 0
bash "$H/auto_pkg.sh" wanted "$G" || { echo "宽屏自动出表：$G 本包满屏关（发布口径、没有补丁开满屏），不起闭环"; exit 0; }   # 同 auto_pkg.sh wanted
A=${S2A_WIDEN_AUTO:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/widen/auto}; mkdir -p "$A" || exit 0
# 两档各出一张（10-24 jhz：通用模式缺省掌机档、直连模式缺省主机档，两种都要宽）：游戏常在同一处按档位分支写两组尺寸，掌机档局里主机档那组不执行，
#   只能各起各的局验；同一个后台任务里先掌机后主机串行跑（同时占两个 Mac 槽没必要）。S2A_LOOP_MODE 给了就只出那一档
M=${S2A_LOOP_MODE:-handheld docked}
# 不用 nohup：没有登录会话的机器（Air）上 /usr/bin/nohup 报「can't detach from console」直接不跑（10-25，见 docs/坑记录.md）
# 自立会话（同 auto_pkg.sh start）：启动器任务结束按会话收残留进程，有意后台照跑的不在任务会话里
# 后台闭环从本树的 clonefile 快照跑、跑完删（11-05）：出壳闭包（pack/shell/closure.py）按访问时间认「出壳读过的文件」，后台闭环在同一棵出包树上
#   读 closed_loop.sh / run_mac.sh / tools/*.py 等 18 个文件，被算成出壳读到 shell.tsv 没登记的文件 → 出壳红（main ae896af59 智慧的再现 08:15 单）；
#   共享出包树上后台局要跑几十分钟，期间同树别的单出壳同样被污染。APFS clonefile 只复制元数据、不读文件，原树访问时间不动（实测 1.3 万项 0.4 秒）。
#   快照失败不退回原树跑（那样又会污染出壳），本次不起，下一个包再起。超 2 天的残留快照（后台被 KILL 没走到收尾）这里顺手删
R=$(cd "$H/../../.." && pwd); SP=${S2A_WIDEN_SNAP:-$(dirname "$R")/.widen_snap}; mkdir -p "$SP" || exit 0; now=$(date +%s)
for d in "$SP"/*; do [ -d "$d" ] || continue; t=${d##*.}; case $t in ''|*[!0-9]*) continue;; esac; [ $((now - t)) -gt 172800 ] && rm -rf "$d"; done
SN=$SP/$G.$$.$now
python3 "$R/tools/clonedir.py" "$R" "$SN" > /dev/null 2>&1 || { rm -rf "$SN"; echo "【黄】宽屏自动出表：$G 出包树快照失败，本次不起闭环（下一个包再起）"; exit 0; }
(trap '' HUP; exec perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV or exit 127' -- bash -c 'trap "rm -rf \"\$4\"" EXIT; for m in $1; do S2A_LOOP_MODE=$m bash "$2" "$3"; done' _ "$M" "$SN/graphics/widen/scan/auto_table.sh" "$G" "$SN") >> "$A/$G.kick.log" 2>&1 < /dev/null &
echo "宽屏自动出表：$G 已交后台（档位 ${M}；结论见 $A/<款>_<构建号>/<档位>.status，下一个包带上）"
exit 0
