#!/bin/bash
# 215 款普查一条命令（能力与泛化线 10-29；与能力关 / 开对照局共用单款流水线 tools/quicktest/one_game.sh → tools/entry_check.sh）：
#   bash tools/census/census.sh <批次目录> [--src <源目录[:源目录…]>] [--hosts mini,air,local]（贡献者一台 Mac：--hosts local，全流程只在本机） [--run-s 300] [--packers 3] [--only <键,…>]
#   --src 不给 = 按资料盘索引表 S2A_LIBRARY_INDEX 取原件路径（11-04 jhz：只查表，不扫目录、不兜底搜索；表由运行区 add_original.sh 维护）；贡献者自有原件照旧 --src 显式给目录
#   ① 盘点（census.py inventory，读得出的清单缓存在 <批次>/inventory/）→ ② 排队（census.py plan，总表已有的款跳过、「未判」重排，断点续跑就是再跑一遍）
#   → ③④ 本机出包工人（--packers 个，缺省 3）按队列直接领款、直读原件（11-04 资料盘 SSD 只读可多读者：删掉机械盘时代的单读盘拷贝工、stage/ 暂存与 stage_need 等盘准入）：
#      源目录 work/<键>/src 只放指向原件路径（索引表 / --src 目录里的路径）的软链，交 one_game.sh 解包 + 出包（QT_PACK_ONLY=1；prod.keys 只在本机）
#      → 出好的工作目录（.qt_packed）进 <批次>/packed/（待跑，最多 CENSUS_PACKED_MAX 款，缺省 = 跑局道数，防本机盘堆满）
#      出包（改写 / 直连库 / Metal 编译，大头）11-04 总指挥方案 A 起提前到出包工人：出包和跑局分道并行，长出包不再停住跑局道（见 packone）
#   → ⑤ 跑局工人（10-29 总指挥：远端每台 2 道、本机 1 道；第 2 道每接一款前核远端 1 分钟负载 < 核数且盘过远端硬闸，不过这轮不接 = 退回 1 道）：本机直接用出好的包、远端 tools/remote.sh --host <机器> 同步出好的工作目录（含产物根），只跑 Mac 局（entry_check，--run-s 秒，到 MARK 后接着玩到局时长）、拉回结果
#      发布口径（10-29 总指挥：普查按全能力跑）：产物根带包内能力清单（改写阶段出、Mac 宿主装载前读），屏幕按 iPhone 17 Pro Max 横屏宽 2346（CENSUS_SCREEN_W）跑，
#      加宽路径真执行；总表记每款实际生效的满屏 / 60帧 / 强信号（census.py caps_state 读 host.log）
#   → ⑥ 每款一行进 <批次>/总表.tsv（census.py row），全部跑完 census.py sum 写 <批次>/汇总.md、打一行三率。
# 资源切分（总指挥 10-29 02:1x：普查不能被正式包阻塞，按资源分开走）：解包在本机（prod.keys 只在本机）；每款出包取所在机器的机器槽
#   （我方机器设 S2A_SLOT_RUN，one_game.sh 出包段前加「$S2A_SLOT_RUN census-<键> --」，与出包队列共用；没设直接跑）；Mac 局在 mini / Air（10-29 06:2x 起本机也可 1 路，见下 local），经 remote.sh
#   的 Mac 局满核槽排队（基础设施线：Mac 局不走 packgate）。远端失败 / 排队超时记「未判」，下次重跑补。
# 要求：批次目录在 $HOME 下（remote.sh 只同步家目录相对路径）；在干净工作树里跑（remote.sh 推当前提交到远端，有未提交改动拒跑）。
# 单测：tests/census_test.sh（规则层 census.py）；单款流水线单测 tests/quicktest_test.sh（含只出包 / 只跑局两档）
set -u
# 自成一个会话组（11-02：本机路和 Air 路从同一个起局脚本起、同组，下面的 trap「kill 0」停一路连带停了另一路，本机路白停 40 分钟）：
#   不是组长就用 setsid 重新执行自己（同一个 pid，调用方的 wait 照旧），每个批次各管各的进程组
if [ -z "${CENSUS_OWN_SESSION:-}" ] && [ "$(ps -o pgid= -p $$ | tr -d ' ')" != "$$" ]; then
  CENSUS_OWN_SESSION=1 exec python3 -c 'import os, sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' "${BASH:-/bin/bash}" "$0" "$@"; fi
# >>> timeout_shim
# 超时一律用仓库 perl 版 tools/bin/timeout（tools/_timeout.sh 口径）：它留在本批进程组里、收到 TERM 转给子组。
#   11-04 c1104_r2：这里没加载，本机道 runone 的 timeout 走了 Homebrew GNU 版（自立进程组），停批的 kill 0 发不到，
#   旧 one_game 续跑到收尾 rm -rf 工作目录，删掉同款新局刚播种的产物根（马力欧惊奇「产物根 → ：」）。单测 tests/census_test.sh ㊾
. "$(dirname "$0")/../_timeout.sh"
# <<< timeout_shim
B=${1:?批次目录}; shift; SRC=; HOSTS=air;   # 10-30 jhz 批：mini 专给列车门禁，普查远端只派 Air（原 mini,air）
 RUN_S=300; ONLY=; PACKERS=3; DATA=; TYPE=
while [ $# -gt 0 ]; do case $1 in
  --data) DATA=$2; shift 2;; --type) TYPE=$2; shift 2;;
  --src) SRC=$2; shift 2;; --hosts) HOSTS=$2; shift 2;; --run-s) RUN_S=$2; shift 2;; --only) ONLY=$2; shift 2;; --packers) PACKERS=$2; shift 2;;
  *) echo "🔴 不认得的参数 $1"; exit 2;; esac; done
# 批次类型（11-04 总指挥）：起批必写 --type 主批|复判|实验，写进 <批次>/.census_batch 一行 type=…；待手测总清单（tools/census/hand_test_list.py）只认主批 / 复判。
#   不给就报红不起批，不设缺省：缺省成哪个都会错——缺省主批，实验批的结论混进手测清单（11-04 DQX 被对照实验批带进清单）；缺省实验，正经普查被悄悄漏掉。
#   批名是人起的会漂，不按批名猜
# >>> batch_type
case $TYPE in 主批 | 复判 | 实验) ;;
  '') echo "🔴【红】起批要写批次类型：--type 主批|复判|实验（待手测总清单只认主批 / 复判），不起批"; exit 2;;
  *) echo "🔴【红】不认得的批次类型 --type ${TYPE}（只认 主批 / 复判 / 实验），不起批"; exit 2;; esac
# <<< batch_type
# 远端工作树名即锁名：主批次 census_<机器>；带 --only 的复现 / 对照批次自动用 census_only_<机器>，不抢主批次的锁（10-29 复现批次占 census_air 挡住主批次 Air 一路）；
#   CENSUS_NAME 可再指定前缀
# 普查走 Mac 过关同一套自动玩家（10-31 起 AI 看屏驾驶：模型看屏点按 + 宿主读数判进局）；建议配 --run-s 420（导航 + MARK 后帧率窗口 + 余量）
NAME=${CENSUS_NAME:-census}; [ -n "$ONLY" ] && [ -z "${CENSUS_NAME:-}" ] && NAME=census_only
R=$(cd "$(dirname "$0")/../.." && pwd); PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}; [ -x "$PY" ] || PY=python3
[ ! -f "$R/tools/data_vol_check.sh" ] || "${BASH:-/bin/bash}" "$R/tools/data_vol_check.sh" || exit 125   # 同 oneclick：数据卷没挂载 / 被真目录替换就明确报错
# 数据放外接盘（10-29 总指挥：--data /Volumes/<外接盘>/census/<批次>，普查不和本机出包 / 列车抢内置盘）：批次目录留在家目录下、做成指向外接盘的链接
#   （remote.sh 按 ~/ 相对路径同步，远端路径不变），出包根 / 暂存 / 拉回的局目录都落外接盘。外接盘没挂上
#   （11-04：不再按余量拒用外接盘，普查也不再自设余量闸——工作盘余量由运维清理器保 ≥200G；本机盘上的解包目录由待跑上限 CENSUS_PACKED_MAX 限量，见 packer）
#   → 新批次打黄「SSD 未就绪，走内置盘」（10-29 总指挥：不当错误，普查进度优先；每款约 1.5 G、跑完即删），批次目录就是普通目录，不静默写错地方；
#   续跑的批次（批次目录已是链接 / 外接盘上已有批次标记）→ 报红停下、写清差多少，不换盘（10-31 运维线：原先删链接改走内置盘，整批从头重跑）；
#   跑到一半外接盘掉了 → 批次标记 .census_batch 不见，整批停（bat_ok）
vol_ok() {   # vol_ok <外接盘目录>：盘挂着 → 0；否则打原因返回 1
  local v; case $1 in /Volumes/?*) v=/Volumes/$(printf '%s' "${1#/Volumes/}" | cut -d/ -f1);; *) echo "--data 要在 /Volumes/<盘> 下：$1"; return 1;; esac
  mount | grep -qF " on $v (" || { echo "外接盘 $v 没挂上"; return 1; }; }
if [ -n "$DATA" ]; then
  if why=$(vol_ok "$DATA"); then mkdir -p "$DATA" && { [ -L "$B" ] || [ ! -e "$B" ]; } && mkdir -p "$(dirname "$B")" && ln -sfn "$DATA" "$B" \
      || { echo "🔴 批次目录 $B 已是普通目录（或建不了链接），不能改放外接盘 $DATA"; exit 2; }
  elif [ -L "$B" ] || [ -e "$DATA/.census_batch" ]; then echo "🔴【红】续跑批次 ${B} 的外接盘没就绪（${why}）：腾出空间 / 挂好盘后重跑，不换到内置盘从头跑"; exit 2
  else echo "🟡【黄】SSD 未就绪（${why}），走内置盘 ${B}；下一批再落外接盘"; fi
fi
mkdir -p "$B"; BL=$(cd "$B" && pwd); B=$(cd "$B" && pwd -P); H=$(cd "$HOME" && pwd -P)
case $BL in "$H"/*) REL=${BL#"$H"/};; *) echo "🔴 批次目录要在家目录下（remote.sh 只同步 ~/ 相对路径；数据放外接盘用 --data）：$BL"; exit 2;; esac
printf 'type=%s\n' "$TYPE" > "$B/.census_batch"   # 批次标记兼批次类型登记（续跑按这次的 --type 重写）
# 本机直连缓存常驻目录（批次所在盘的上一级，跨批次复用；外接盘批次就在外接盘）与删除工具（我方机器有 safe_rm.sh 就走它）
# >>> dcache_pick（单测 census_test 60 抽这段）
# 本机直连缓存（11-04 一次成功线：原先缺省是普查自己的 <批次上级>/census_dcache、总量上限 40 GB，只装得下约 12 款，
#   每款下次出包时早被淘汰、Metal 全冷编（c1104_r2 奥德赛 669 支冷编 2061 秒；共享缓存 cache/direct 里有它却不用）。
#   改为缺省用运行区共享直连缓存 S2A_XLATE_CACHE（layout.env，工作盘清理器按 WORK_XLATE_CAP_GB 管，在用 / 30 分钟内动过的不删），
#   不再自带 40 GB 淘汰；只有显式给 CENSUS_DCACHE 或没有 S2A_XLATE_CACHE（贡献者单机）时才用私有目录 + dcache_gc 上限
DCACHE=${CENSUS_DCACHE:-${S2A_XLATE_CACHE:-}}; DCACHE_GC=0; [ -n "$DCACHE" ] || { DCACHE=$(dirname "$B")/census_dcache; DCACHE_GC=1; }
[ -n "${CENSUS_DCACHE:-}" ] && DCACHE_GC=1; mkdir -p "$DCACHE"
# <<< dcache_pick
# >>> save_pick（单测 census_test 61 抽这段）
# 存档口径（11-04 总指挥定）：普查主数字一律不带存档，本机 / Air / mini 统一——「一次成功」= 玩家第一次装上就能玩，首次启动必须测到；
#   原先本机局按构建号自动带 saves/ 里的社区存档、远端存档库是空的，同一款结论随机器变（生化奇兵首次启动条款页死循环被本机存档掩盖）。
#   CENSUS_SAVES=none（缺省）：S2A_SAVES 指一个不存在的目录（tools/mac_save.sh 找不到就不带存档），清掉调用方漏进来的 S2A_SAVE_DIR / S2A_SYSTEM_TIME，远端同样；
#   CENSUS_SAVES=lib：照旧按存档库自动带（只给「存档复判批」用，结论单列、不并进主数字）
CENSUS_SAVES=${CENSUS_SAVES:-none}; RSAVE=
case $CENSUS_SAVES in
  none) export S2A_SAVES=$B/.不带存档; unset S2A_SAVE_DIR S2A_SYSTEM_TIME; RSAVE='export S2A_SAVES=$HOME/.s2a_census_no_saves; unset S2A_SAVE_DIR S2A_SYSTEM_TIME; ';;
  lib) ;;
  *) echo "🔴 CENSUS_SAVES 只认 none（缺省，不带存档）/ lib（存档复判批）：$CENSUS_SAVES"; exit 2;;
esac
# <<< save_pick
[ -f "${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/bin/safe_rm.sh" ] && export S2A_SAFE_RM=${S2A_SAFE_RM:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/bin/safe_rm.sh}
bat_ok() { [ -e "$B/.census_batch" ] && return 0; echo "🔴【红】普查目录 $B 不见了（外接盘掉了？），停整批，不往内置盘补写" >&2; kill -TERM $$; exit 1; }
if [ -z "$SRC" ]; then   # 资料盘索引表：census.py src_files 按表取路径
  [ -n "${S2A_LIBRARY_INDEX:-}" ] || { echo "🔴 没给 --src，也没设 S2A_LIBRARY_INDEX（资料盘索引表）"; exit 2; }
  [ -f "$S2A_LIBRARY_INDEX" ] || { echo "🔴 索引表不在：${S2A_LIBRARY_INDEX}（资料盘挂上了吗）"; exit 2; }
  SRC=@$S2A_LIBRARY_INDEX
else IFS=: read -r -a SRCS <<< "$SRC"; for d in "${SRCS[@]}"; do [ -d "$d" ] || { echo "🔴 源目录不在（硬盘挂上了吗）：$d"; exit 2; }; done; fi
case ",$HOSTS," in ,local,) ;;   # 只在本机跑（贡献者只有一台 Mac，10-29）：不经 remote.sh，不要求干净工作树
  *) [ -z "$(git -C "$R" status --porcelain --untracked-files=no)" ] || { echo "🔴 工作树有未提交改动：remote.sh 推的是当前提交，先提交再跑"; exit 2; };; esac
L=$B/批次.log; T=$B/总表.tsv; PQ=$B/packed; mkdir -p "$B/work" "$PQ" "$B/running"
# Air 路本地化（jhz 11-02「密钥放 Air / mini，Air 本地完成」）：CENSUS_AIR_LOCAL=1 且只有 air 一台跑局机器时，原件直接推到 Air 的 2T（CENSUS_AIR_SRC/<键>/），
#   在 Air 上本地解包 + 出包 + 跑局（Air 有 prod.keys）；本机不再读原件做解包、不 rsync extract，只拉回结果 r/ 和一小份 exefs（api_census 用）
# >>> air_conf
AIRLOCAL=${CENSUS_AIR_LOCAL:-0}; AIRSRC=${CENSUS_AIR_SRC:-${S2A_AIR_SRC:-}}   # Air 上放原件的目录：CENSUS_AIR_SRC 显式给优先，否则取 layout.env 的 S2A_AIR_SRC（不写字面路径进仓库）
# Air 侧配置键校验（11-04：从 layout.env source，缺键报红退出；不在脚本里写死路径）
if [ "$AIRLOCAL" = 1 ]; then
  [ -n "$AIRSRC" ] || { echo "🔴 CENSUS_AIR_LOCAL=1 但没有 Air 原件目录：CENSUS_AIR_SRC 和 layout.env 的 S2A_AIR_SRC 都没给（source ~/.s2arm/run/s2arm/env/layout.env）" >&2; exit 2; }
  for _k in S2A_AIR_WORK S2A_AIR_CAP_GB S2A_AIR_CAP_UNPACK_GB S2A_AIR_CAP_RUNS_GB S2A_AIR_CAP_ROOTS_GB; do
    eval "_v=\${${_k}:-}"; [ -n "$_v" ] || { echo "🔴 CENSUS_AIR_LOCAL=1 但 layout.env 缺键 ${_k}（source ~/.s2arm/run/s2arm/env/layout.env）" >&2; exit 2; }
  done
fi
# <<< air_conf
# 本机也跑局（jhz 10-29 06:2x「本机是性能最强的设备，理应参与核心任务」）：--hosts 写 local，只 1 路（runner 一台一个），整局墙钟超时 CENSUS_LOCAL_S；
#   走全机 Mac 局槽 tools/mac_slot.sh（与别线本机局共用）。风险：GPU 挂死会拖死整机（10-19 内核恐慌），超时兜不住内核级挂死
log() { echo "[$(date '+%m-%d %T')] $*" | tee -a "$L"; }
# >>> work_rm（单测 census_test 58i 按这两行标记抽出来测）
# 删款工作目录统一走 pack/roots.sh 的 _root_rm（11-04，同 one_game.sh qt_rm 口径）：work/<键>/p 里有产物根的 RomFS 共享存储（roots/.romfs_store/ 整棵只读），
#   局被杀、one_game 没跑到收尾时裸 rm -rf 删不掉、逐文件报 Permission denied、漏盘；删不掉写一行【红】（路径 + 报错条数 + 首条原因），rm 的逐文件报错不进日志
. "$R/pack/roots.sh"
work_rm() { local e; e=$(_root_rm "$1" 2>&1 > /dev/null | awk 'NR == 1 {f = $0} END {if (NR) print NR " 条报错，首条：" f}'); [ -e "$1" ] || [ -L "$1" ] || return 0; log "【红】普查：删不掉 ${1}（${e:-rm 没报原因}）"; return 1; }
# <<< work_rm
# >>> _wait_helpers（单测 census_test ㊵ 按这两行标记抽出来测）
# _wait_tick <状态文件> <标签>：首次进等待写【黄】，之后每 10 分钟一次；超 CENSUS_WAIT_RED_S（缺省 1800 秒 = 30 分钟）时写【红】并调 CENSUS_ALERT_CMD（只调一次）
_wait_tick() {
  local w=$1 label=$2 now t0 t1 red
  now=$(date +%s)
  if [ -f "$w" ]; then read -r t0 t1 red < "$w"; else t0=$now; t1=0; red=0; fi
  : "${t0:=$now}"; : "${t1:=0}"; : "${red:=0}"
  if [ $((now - t1)) -ge 600 ]; then
    t1=$now
    log "【黄】等盘：${label}，已等 $(( (now - t0) / 60 )) 分钟"
  fi
  if [ $((now - t0)) -ge "${CENSUS_WAIT_RED_S:-1800}" ] && [ "${red}" = 0 ]; then
    red=1
    log "【红】等盘超 $(( ${CENSUS_WAIT_RED_S:-1800} / 60 )) 分钟：${label}"
    [ -n "${CENSUS_ALERT_CMD:-}" ] && bash -c "$CENSUS_ALERT_CMD '【红】等盘超 $(( ${CENSUS_WAIT_RED_S:-1800} / 60 )) 分钟：$(basename "${B:-?}") ${label}'" 2>/dev/null || true
  fi
  printf '%s %s %s\n' "$t0" "$t1" "${red}" > "$w"
}
# _wait_done <状态文件> <标签>：条件满足，写「盘已够」行并清状态文件；未曾等待（文件不存在）则静默返回。这行不能带「等盘」二字：运维 ops_status.py 按子串判拷贝工 / 批次在等盘
_wait_done() {
  local w=$1 label=$2 t0
  [ -f "$w" ] || return 0
  { read -r t0 _ < "$w"; } 2>/dev/null || t0=$(date +%s)
  log "盘已够，等了 $(( ($(date +%s) - t0) / 60 )) 分钟：${label}"
  rm -f "$w"
}
# <<< _wait_helpers
log "批次 $(basename "$B")（${TYPE}）：提交 $(git -C "$R" rev-parse --short HEAD)，源 ${SRC}，本机出包 $PACKERS 路，跑局机器 ${HOSTS}，局 $RUN_S 秒"
"$PY" "$R/tools/census/census.py" inventory "$SRC" "$B" | tee -a "$L"; [ "${PIPESTATUS[0]}" = 0 ] || { log "【红】盘点没过（见上，机器原因不记成游戏），停批"; exit 1; }   # 没开 pipefail：|| 只看得到 tee 的退出码
"$PY" "$R/tools/census/census.py" plan "$B" | tee -a "$L" || exit 1
Q=$B/queue.tsv
if [ -n "$ONLY" ]; then awk -F'\t' -v o=",$ONLY," 'NR == 1 || index(o, "," $1 ",")' "$Q" > "$Q.only" && mv "$Q.only" "$Q"; fi
n=$(($(grep -c . "$Q") - 1)); [ "$n" -gt 0 ] || { log "没有要跑的款"; "$PY" "$R/tools/census/census.py" sum "$B" | tee -a "$L"; exit 0; }

# >>> air_push
# air_push <ssh目标> <键> <字节数> <文件…>：从资料盘 S2A_LIBRARY（SSD 只读、可多读者）rsync 到 Air 的 $AIRSRC/<键>/。
#   远端已有同名同大小的跳过（不记已推）；rsync 只带 -a（保 mtime）。全部成功返回 0，任一失败返回 1（调用方停这一款）。
#   11-04 重做：资料盘已是 SSD，删掉机械盘读锁路径（机械盘已退役）。
air_push() {
  local sh=$1 k=$2 sz=$3 f b n r todo=(); shift 3
  ssh -o BatchMode=yes -o ConnectTimeout=8 "$sh" "mkdir -p '$AIRSRC/$k'" || return 1
  for f in "$@"; do b=$(basename "$f"); n=$(stat -f %z "$f" 2> /dev/null); r=$(ssh -o BatchMode=yes -o ConnectTimeout=8 "$sh" "stat -f %z '$AIRSRC/$k/$b' 2> /dev/null" 2> /dev/null)
    [ -n "$n" ] && [ "$r" = "$n" ] || todo+=("$f"); done
  [ ${#todo[@]} -gt 0 ] || return 0
  echo "$k" >> "$B/.air_pushed"   # 本批推过的键（推之前记，推到一半断了也算）：批停 / 结束只删这些（air_src_purge）
  rsync -a "${todo[@]}" "$sh:$AIRSRC/$k/" || return 1
  return 0
}
# <<< air_push
# >>> air_rsh
# air_rsh <ssh目标> <连接超时秒> [参数…]：stdin 的脚本在 Air 上用 bash 跑。ssh 不传本机环境变量、Air 登录 shell 是 zsh（11-04 复核实测 Air 上 S2A_AIR_WORK 为空，
#   上一版 ${S2A_AIR_WORK:?} 在真 Air 上直接失败、被 || true 吞掉）→ 脚本要的值一律作位置参数显式传（printf %q 转义），远端脚本不读环境变量
air_rsh() { local sh=$1 to=$2; shift 2; ssh -o BatchMode=yes -o ConnectTimeout="$to" "$sh" "bash -s -- $(printf '%q ' "$@")"; }
# <<< air_rsh
# >>> air_cleaner
# air_cleaner <ssh目标> [保护键…]：每款开跑前同步清一轮 Air 工作区 S2A_AIR_WORK 下可再生目录：cache/unpack、runs、roots 各按 S2A_AIR_CAP_UNPACK / RUNS / ROOTS_GB 上限，
#   超了按最久未改先删；子目录名含保护键的不删（本批在跑的款）。工作区和上限取本机 layout.env 的值、作参数传过去。
#   单实例：Air 没有 flock（11-04 实测），用 mkdir 锁目录 <工作区>/.air_cleaner.lock + pid 文件；持锁进程已不在 = 死锁，收回再拿；持锁进程还在 = 等它清完（最多 CENSUS_AIR_LOCK_WAIT_S，缺省 60 秒；是等锁不是等盘），超时本轮不清、只量盘。
#   打一行：收回死锁 / 删了什么 / 各区清后与上限 / 卷剩余「free=<GB>G」（结尾）；连不上 Air 或工作区不在则没有 free= 段
air_cleaner() {
  local sh=$1; shift
  air_rsh "$sh" 90 "$S2A_AIR_WORK" "$S2A_AIR_CAP_UNPACK_GB" "$S2A_AIR_CAP_RUNS_GB" "$S2A_AIR_CAP_ROOTS_GB" "${CENSUS_AIR_LOCK_WAIT_S:-60}" "$@" << 'AIRSH' 2> /dev/null
set -u
W=$1 CU=$2 CR=$3 CO=$4 LW=$5; shift 5; PK="$*"
[ -n "$W" ] && [ -d "$W" ] || { echo "Air 工作区不在：${W:-（空）}"; exit 3; }
free() { df -k "$W" | tail -1 | awk '{print int($4 / 1048576)}'; }
LK=$W/.air_cleaner.lock; RC=; i=0
until mkdir "$LK" 2> /dev/null; do
  p=$(cat "$LK/pid" 2> /dev/null); [ -n "$p" ] || { sleep 1; p=$(cat "$LK/pid" 2> /dev/null); }   # 刚建目录还没写 pid 的那一瞬
  if [ -n "$p" ] && kill -0 "$p" 2> /dev/null; then   # 别的清理器在清（同批解包工人 / 别道同时到）：等它清完，最多 CENSUS_AIR_LOCK_WAIT_S（缺省 60）秒，是等锁不是等盘
    i=$((i + 1)); [ "$i" -le "$LW" ] || { echo "锁占用 ${LW} 秒（pid ${p}），本轮不清 free=$(free)G"; exit 0; }; sleep 1; continue; fi
  rm -rf "$LK"; RC="收回死锁（pid ${p:-无}）；"
done
echo $$ > "$LK/pid"; trap 'rm -rf "$LK"' EXIT
mb() { du -sk "$1" 2> /dev/null | awk '{s += $1} END {print int(s / 1024)}'; }
DEL=; REP=
evict() {   # evict <子目录> <上限GB>
  local d=$W/$1 cap s sub m k sum
  cap=$(awk -v g="$2" 'BEGIN{printf "%d", g * 1024}')
  [ -d "$d" ] || { REP="$REP $1=0/${cap}M"; return; }
  sum=$(mb "$d")
  while [ "$sum" -gt "$cap" ]; do sub=
    for s in $(ls -1tr "$d"); do for k in $PK; do case $s in *"$k"*) continue 2;; esac; done; sub=$s; break; done
    [ -n "$sub" ] || break
    m=$(mb "$d/$sub"); rm -rf "${d:?}/$sub"; DEL="$DEL $1/$sub(${m}M)"; sum=$((sum - m))
  done
  REP="$REP $1=${sum}M/${cap}M"; }
evict cache/unpack "$CU"; evict runs "$CR"; evict roots "$CO"
echo "${RC}删${DEL:- 无}；清后${REP} free=$(free)G"
AIRSH
}
# <<< air_cleaner
# >>> air_disk_gate
# air_disk_gate <键> <名> <版本> <源GB> <还要推到 Air 的GB>：Air 盘准入（11-04 复核：替代 Air 的 disk_ok 等盘循环，不等）。
#   先跑一轮 air_cleaner（保护本批在跑款 + 这款），再拿清后剩余比需求：需求 = disk_ok 同一预估（S2A_REMOTE_EST_R × 源 + S2A_REMOTE_EST_C：解包 + 出包 + 直连缓存峰值，
#   11-01 Air 8 款实测拟合）+ 还没推过去的原件 + 硬闸 S2A_REMOTE_MIN_FREE_GB（缺省 20）。够 → 0；不够 / 量不到 → 记【红】Air 盘不足（总表未判 = 机器原因，下批重排），返回 1
air_disk_gate() {
  local k=$1 nm=$2 ver=$3 gb=$4 pend=$5 e need out fr why res
  e=$(awk -v g="$gb" -v r="${S2A_REMOTE_EST_R:-4.5}" -v c="${S2A_REMOTE_EST_C:-14}" 'BEGIN{printf "%d", r * g + c + 0.999}')
  need=$(awk -v e="$e" -v p="$pend" -v f="${S2A_REMOTE_MIN_FREE_GB:-20}" 'BEGIN{printf "%d", e + p + f + 0.999}')
  out=$(air_cleaner "$AIRSH" $(ls "$B/running" 2> /dev/null) "$k")
  log "Air 工作区清理（${k}）：${out:-连不上 Air}"
  fr=$(printf '%s' "$out" | sed -n 's/.*free=\([0-9][0-9]*\)G$/\1/p')
  [ -n "$fr" ] && [ "$fr" -ge "$need" ] && return 0
  why="Air 可用 ${fr:-?（量不到）} GB / 需 ${need} GB（源 ${gb} GB 预估峰值 ${e} G + 待推原件 ${pend} G + 硬闸 ${S2A_REMOTE_MIN_FREE_GB:-20} G），已清理一轮，不等"
  log "【红】Air 盘不足，跳过 $k ${nm}：$why"
  res=$B/.airdisk.$k.tsv; printf '结论\t第一个失败点\n未判\t【红】Air 盘不足：%s\n' "$why" > "$res"
  CENSUS_FAIL_LIST="$B/直连编不过清单.tsv" "$PY" "$R/tools/census/census.py" row "$k" "$nm" "$ver" air "$gb" "$res" >> "$T"; rm -f "$res"
  return 1
}
# <<< air_disk_gate
# >>> air_mem_ok
# air_mem_ok <ssh目标> <道号>：Air 16 GB 内存准入，第 2 道起接款前判（第 1 道不限）。过 → 0；不过 → 打原因、返回 1（这轮不接 = 只开 1 道，不交换）。
#   每款内存预估 CENSUS_AIR_MEM_EST_GB（缺省 5.5；Air 归出包速度线独占、普查不派，11-06 宿主上限改 7.5 GB 时没跟着动）：总表没有内存列，没有按款 / 按引擎的内存历史可用 →
#   用保守常数：按旧的普查局宿主内存上限 5 GB + 0.5 GB 宿主外进程余量（未实测）定的；11-06 宿主上限改 7.5 GB（one_game.sh QT_MEM_MB 缺省 7680），Air 不跑普查，这里没跟着改。
#   三条都过才接：① 内核内存压力级别 = 1（正常；2 警告 / 4 危急）；② 静态账 物理内存 − 常驻（wired）− 预估 ×（在跑款数 + 1）≥ 0；
#   ③ 实时账 可用（free + inactive + speculative + purgeable，按 vm_stat 自报页大小，Air 是 16 KB）− 预估 ≥ CENSUS_AIR_MEM_MARGIN_GB（缺省 1）。
#   出包重款（Pokopia 编批库实测 dsh_batch 5.3 GB + metal 合计 5.1 GB，pokometal_detail §3）超出常数，由 ① ③ 的实时读数兜：重款在跑时可用掉下去，第 2 道不接。
#   不再看交换已用量：Air 空闲时交换已用 2.4 GB 且不回落（11-04 实测），按「交换 < 2 GB」判第 2 道永远不过
air_mem_ok() {
  local sh=$1 lane=$2 est mg n o lv mem av wd s a
  [ "$lane" = 1 ] && return 0
  est=${CENSUS_AIR_MEM_EST_GB:-5.5}; mg=${CENSUS_AIR_MEM_MARGIN_GB:-1}; n=$(grep -lx air "$B"/running/* 2> /dev/null | wc -l | tr -d ' ')   # 只数 Air 在跑的（claim 写机器名；11-04 数全部时本机 3 道在跑 → 第 2 道永远不过）
  o=$(air_rsh "$sh" 8 << 'AIRSH' 2> /dev/null
l=$(sysctl -n kern.memorystatus_vm_pressure_level); m=$(sysctl -n hw.memsize)
vm_stat | awk -v l="$l" -v m="$m" 'NR == 1 {for (i = 1; i <= NF; i++) if ($i == "of") ps = $(i + 1)}
  /^Pages (free|inactive|speculative|purgeable):/ {v = $NF; sub(/\./, "", v); a += v} /^Pages wired down:/ {v = $NF; sub(/\./, "", v); w = v}
  END {printf "%s %d %d %d\n", l, m / 1048576, a * ps / 1048576, w * ps / 1048576}'
AIRSH
)
  read -r lv mem av wd < <(printf '%s\n' "$o")
  [ -n "${wd:-}" ] || { echo "量不到 Air 内存"; return 1; }
  s=$(awk -v M="$mem" -v W="$wd" -v e="$est" -v n="$n" 'BEGIN{printf "%d", M - W - e * 1024 * (n + 1)}')
  a=$(awk -v A="$av" -v e="$est" 'BEGIN{printf "%d", A - e * 1024}')
  local tag="压力级别 ${lv}，物理 ${mem} MB − 常驻 ${wd} MB − ${est} GB ×（在跑 ${n} + 1）= ${s} MB；可用 ${av} MB − ${est} GB = ${a} MB"
  [ "$lv" = 1 ] || { echo "内存压力非正常：$tag"; return 1; }
  [ "$s" -ge 0 ] || { echo "静态账不够：$tag"; return 1; }
  [ "$a" -ge "$(awk -v g="$mg" 'BEGIN{printf "%d", g * 1024}')" ] || { echo "实时可用不够：$tag"; return 1; }
  return 0
}
# <<< air_mem_ok
# >>> air_src_rm
# air_src_rm <ssh目标> <键…>：删 Air 上 $AIRSRC/<键>（只删点名的键；键里带 / 或空的跳过）。air_src_delete 判完即删一款，air_src_purge 批停 / 结束删本批推过的全部
air_src_rm() {
  local sh=$1; shift; [ $# -gt 0 ] || return 0
  air_rsh "$sh" 15 "$AIRSRC" "$@" << 'AIRSH' 2> /dev/null
S=$1; shift; [ -n "$S" ] && [ -d "$S" ] || exit 0
for k in "$@"; do case $k in '' | */* | . | ..) continue;; esac; rm -rf "${S:?}/$k"; done
AIRSH
}
air_src_delete() { air_src_rm "$1" "$2"; }   # air_src_delete <ssh目标> <键>：结论行写进总表后当场删 Air 上这款原件目录（不靠外部看守）
# air_src_purge <ssh目标>：只删本批推过去的键（air_push 记在 $B/.air_pushed）；同在 Air 上跑的别批（census_only_air_* 等）的原件不动（11-04 复核：原先删 $AIRSRC/* 全部）
air_src_purge() { [ -s "$B/.air_pushed" ] || return 0; air_src_rm "$1" $(sort -u "$B/.air_pushed") && rm -f "$B/.air_pushed"; }
# <<< air_src_rm
# >>> air_metrics
# air_metrics_sampler：Air 道每 CENSUS_AIR_METRICS_S（缺省 60）秒采一行到 <批次>/air_metrics.tsv：时间、Air 工作区（S2A_AIR_WORK）所在盘可用 GB（列名 ssd_free_gb 沿用，11-05 起 Air 无 SSD、是内置盘）、交换已用 MB、内存压力级别、本批在跑款、
#   距本批最后一条结论行的分钟数（总表最后一次写入的时刻，早于本批开跑按开跑时刻算）。批结束由主流程 air_batch_end 停采样器、读这张表出汇总行（11-04 复核：
#   原先汇总写在采样循环尾，主流程 kill 掉循环，汇总永远不出）
air_metrics_sampler() {
  local mf="$B/air_metrics.tsv" t0 o fr sw lv tl mins
  t0=${s0:-$(date +%s)}   # 本批开跑时刻（主流程 s0）
  [ -s "$mf" ] || printf 'time\tssd_free_gb\tswap_used_mb\tmem_pressure\trunning_keys\tmins_since_last_row\n' > "$mf"
  while [ -e "$B/.census_batch" ]; do
    o=$(air_rsh "$AIRSH" 5 "$S2A_AIR_WORK" << 'AIRSH' 2> /dev/null
f=$(df -k "$1" 2> /dev/null | tail -1 | awk '{print int($4 / 1048576)}')
s=$(sysctl -n vm.swapusage 2> /dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "used") {v = $(i + 2); sub(/M$/, "", v); print int(v)}}')
echo "${f:--} ${s:--} $(sysctl -n kern.memorystatus_vm_pressure_level 2> /dev/null || echo -)"
AIRSH
)
    read -r fr sw lv < <(printf '%s\n' "$o")
    tl=$(stat -f %m "$T" 2> /dev/null || echo 0); [ "$tl" -gt "$t0" ] || tl=$t0
    mins=$(( ($(date +%s) - tl) / 60 ))
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date '+%m-%d %T')" "${fr:--}" "${sw:--}" "${lv:--}" "$(ls "$B/running" 2> /dev/null | paste -sd, -)" "$mins" >> "$mf"
    sleep "${CENSUS_AIR_METRICS_S:-60}"
  done
}
# air_metrics_summary <tsv>：一行汇总（盘最低剩余 / 交换最大 / 最长无进展），只算数字格
air_metrics_summary() {
  awk -F'\t' 'NR > 1 {n++; if ($2 ~ /^[0-9]+$/ && (f == "" || $2 + 0 < f)) f = $2 + 0; if ($3 ~ /^[0-9]+$/ && $3 + 0 > s) s = $3 + 0; if ($6 ~ /^[0-9]+$/ && $6 + 0 > g) g = $6 + 0}
    END {if (!n) print "Air 指标汇总：没有采样行"; else printf "Air 指标汇总：盘最低剩余 %s GB，交换最大 %d MB，最长无进展 %d 分钟（%d 行）\n", (f == "" ? "?" : f), s, g, n}' "$1" 2> /dev/null; }
# air_batch_end：批结束（跑局工人全退后）停采样器 → 驱动日志打汇总 → 删本批推到 Air 的原件
air_batch_end() {
  [ -n "${AIRMETRICS:-}" ] && { kill "$AIRMETRICS" 2> /dev/null; wait "$AIRMETRICS" 2> /dev/null; }
  log "$(air_metrics_summary "$B/air_metrics.tsv")"
  air_src_purge "$AIRSH"; log "Air 上本批原件已删"
}
# <<< air_metrics
# 60 帧逻辑速度同局 A/B（11-02 总指挥：普查一局判，结论进 docs/名单_60帧逻辑速度.tsv；60 帧全引擎默认开，判红自动关）：
#   S2A_AP_SPEED=ab 自动玩家 MARK 后开→关→开三段测 ρ / q（tests/autoplay speed_ab）；S2A_FPS_AB=1 让包内 60 帧没开的款（强信号关的）也能在开段放开出图间隔
#   （runtime/src/caps.c 设 DM_PRESENT_INTERVAL=display，平时 fps.c 降档原因 3 照原帧率跑，五问读数不变）。CENSUS_FPS_AB=0 关
FAB=; [ "${CENSUS_FPS_AB:-1}" = 1 ] && FAB="S2A_AP_SPEED=ab S2A_FPS_AB=1"
# 只跑原生档（11-02 15:5x jhz：普查只证原生帧率 + 16:9 画幅一次打通，满屏 / 60 帧以后由补丁包解决）：CENSUS_NATIVE_ONLY=1 时主局就按原生档跑——
#   60 帧关、满屏放宽关、屏宽 1920（16:9），也不再补跑第二局原生档；出包与能力无关（one_game.sh 原生档注释），照常出
#   逻辑速度 A/B 照挂（11-04 总指挥：原生档主局也要补逻辑速度证据，不另起实验局）：A/B 是 MARK 后改出帧状态的段，照常窗口从段结束起算（S2A_AP_EARLY_S），
#   帧率 / 卡顿 / 帧节拍判据剔掉段内帧（tools/ab_span.py）；S2A_FPS_AB=1 下 60 帧关的款平时照原帧率跑，只在测开段放开
[ "${CENSUS_NATIVE_ONLY:-0}" = 1 ] && { FAB="S2A_FPS60=0 S2A_WIDEN_CAPS=0 S2A_WIDEN_VERIFIED=0${FAB:+ $FAB}"; CENSUS_NATIVE_TIER=0; }
# 提前收局（11-04 总指挥：普查只判出包 / 进局 / 不崩 / 不卡死，到 MARK 后不再玩到 --run-s）：自动玩家 MARK 后登记的段（逻辑速度 A/B、声音稳态窗口…）全部跑完、
#   且 A/B 测完后照常出帧 CENSUS_EARLY_S 秒（缺省 60：五问帧率窗口要 MARK 后 ≥ 55 秒、声音稳态窗口 60 秒、卡死判据 60 秒同量级）就收局；没到 MARK 照旧给满局时。0 = 关
FAB="$FAB S2A_AP_EARLY_S=${CENSUS_EARLY_S:-60}"
# 原生档（11-02 jhz）：局内失败（崩溃类）或不崩没出图的款，one_game.sh 同一产物根再跑一局能力全关（16:9 + 原生帧率），总表「原生档」列；CENSUS_NATIVE_TIER=0 关
export CENSUS_FPS_AB_LIST="$B/逻辑速度.tsv"   # census.py row 每款把同局 A/B 结论追加进这里（没有那一行就不写）
SW=${CENSUS_SCREEN_W:-$([ "${CENSUS_NATIVE_ONLY:-0}" = 1 ] && echo 1920 || echo 2346)}   # 普查局屏幕宽（游戏 1080 高对应的宽）：iPhone 17 Pro Max 横屏 2868×1320 → 2346（graphics/widen/export/s2a_widen.h）；entry_check 缺省 1922 加宽几乎不走
# >>> wall_s（单测 census_test 62 抽这段）
# 普查出包 / 整局墙钟只作最后兜底（11-04 总指挥：固定 4200 / 5400 秒杀掉的是还在进展的冷出包大作——r2 海贼无双4、勇者XI S、天际、七龙珠Z、王国之泪
#   5 款全是退出码 124、判不出结论；防卡死靠出包各段的无进展看门狗 tools/nostall.py（S2A_NOSTALL_S，缺省 600 秒））：
#   上限 = CENSUS_WALL_BASE_S（缺省 3600）+ CENSUS_WALL_PER_GB_S（缺省 1800）× 源 GB；显式给 CENSUS_LOCAL_S / CENSUS_REMOTE_S 的照旧为准
wall_s() { awk -v g="${1:-0}" -v b="${CENSUS_WALL_BASE_S:-3600}" -v r="${CENSUS_WALL_PER_GB_S:-1800}" 'BEGIN{printf "%d", b + r * (g + 0)}'; }
# <<< wall_s
norun_why() {   # 没跑成 / 记未判时写原因（11-03 总指挥：P5 对战版第 2 次「没跑成」日志空白——跑满本机墙钟上限被 timeout 杀掉，不留红行，判据会绿着失效）：
  #   有红行取最后一条红行；没有就按退出码说明：124 / 137 = 墙钟超时被杀；其它写退出码、实跑秒数和 run.out 末行
  local r; r=$(grep -a -E '🔴|【红】' "$W/run.out" 2> /dev/null | tail -1 | cut -c1-120); [ -n "$r" ] && { echo "$r"; return; }
  case ${rc:-} in 124|137) echo "墙钟超时：跑满兜底上限 ${WALL:-?} 秒（按源 ${gb:-?} GB 算）被杀，实跑 $((SECONDS - t0)) 秒，没写出结果行";;
    *) echo "没写出结果行（退出码 ${rc:-?}，实跑 $((SECONDS - t0)) 秒；run.out 末行：$(tail -1 "$W/run.out" 2> /dev/null | cut -c1-80)）";; esac; }
runone() {   # runone <机器> <键> [道]：解包目录同步到跑局那台 → 那台出包（全量 + 直连，发布口径）并跑 Mac 局 → 拉回结果、总表一行；
  local t0=$SECONDS rc=   # 没跑成时写原因用（norun_why）
  #   远端同步的解包副本跑完即删（remote.sh 局后清），出包产物在远端工作目录、跑完即删，不拉回。远端没跑成返回 2（不记行、不删解包，runner 放回待跑）
  local h=$1 k=$2 W=$B/work/$2 nm ver gb rc us ln=${3:-1} X; bat_ok
  IFS=$'\t' read -r nm ver gb < "$W/meta"; local WALL; WALL=$(wall_s "$gb" 2> /dev/null); us=$(cat "$W/p/logs/$k/unpack_s" 2> /dev/null || echo 0); X=work/$k/p/work/$k/extract
  # 起局时那台的满核槽在用 + 排队数（11-01 总指挥：Air 同时跑的 Mac 局多会把帧率读数拖成假红，五问行要记；autorun.py 读 <款>/air_concurrent）
  if [ "$h" = local ]; then echo "local -" > "$W/air_concurrent"; else echo "$h $(bash "$R/tools/remote.sh" --host "$h" --load 2> /dev/null | tail -1)" > "$W/air_concurrent"; fi
  # 解包工人已出好包（packone QT_PACK_ONLY，.qt_packed）：源给出好的工作目录 = 只跑局（本机直接用；远端同步这个目录，含产物根）。
  #   出包段的日志（oneclick.log / *.red / direct_fail.tsv / direct_build.log / timing.tsv，census.py 从 r/logs/<键> 读）与 exefs 留在 p/logs/<键>，局后并进 r/logs
  local PKL=; [ -f "$W/p/work/$k/.qt_packed" ] && { X=work/$k/p/work/$k; PKL=$W/p/logs/$k; }
  if [ "$AIRLOCAL" != 1 ] && [ ! -d "$B/$X" ]; then   # 既没有解包目录也没有出好的包（旧流程中途停下的残留）：不占道、不记行，删掉工作目录，下次普查按「总表没有」重排
    log "【黄】$k ${nm}：待跑款没有解包目录也没有出好的包，丢回下次普查重排"; work_rm "$W"; return 0; fi
  if [ "$h" = local ]; then   # 本机：直接跑，局槽排队上限 600 秒，整局（直连 → 通用 + 崩了补跑）墙钟 CENSUS_LOCAL_S
    #   只跑局（PKL）时带 QT_KEEP=1：one_game 只跑局模式收尾会删源（= 本机这份出好的包），局槽被占 / 没跑成放回待跑时就没包可跑了；用完由下面收尾 work_rm 删
    # 直连库中间缓存每台机器常驻、按款分目录、带总量上限（11-01 总指挥批：原先放这款工作目录、跑完即删，每款每次普查都全冷，勇者斗恶龙 XI 出库 1 小时）：
    #   用前 dcache_gc.py 记用过、超上限按最久没用的款淘汰（在用的不动）；本机上限 CENSUS_DCACHE_GB（缺省 40）
    # 机器槽（S2A_SLOT_RUN，与出包队列共用）在计时外取：先拿槽、拿到后才起 CENSUS_LOCAL_S 墙钟，整款（出包 + Mac 局）占一个槽；
    #   内层去掉 S2A_SLOT_RUN，one_game.sh 不再自己取槽。10-31：槽取在计时里面时，出包队列占满 3 槽超过 70 分钟，3 款还没出包就超时、
    #   被记「没跑成」放回，连续 3 次会记成「未判」（基础设施原因错记到款头上）
    local sw=(); [ -n "${S2A_SLOT_RUN:-}" ] && { read -r -a sw <<< "$S2A_SLOT_RUN"; sw+=("census-$k" --); }
    #   淘汰放后台（11-02：dcache_gc 每次全量 os.walk 量所有款的体积，2T 上缓存里有几十万小文件时一次要 13 分钟，跑局道在起局前就被卡住、
    #   本机主段 1.5 小时只出 3 行）；本次的款先在前台记「用过」（.used）保证不被这一轮淘汰，在用的款 gc 自己按 .inuse 锁跳过
    mkdir -p "$DCACHE/$k" && touch "$DCACHE/$k/.used"
    [ "${DCACHE_GC:-1}" = 1 ] && ( "$PY" "$R/tools/census/dcache_gc.py" "$DCACHE" "${CENSUS_DCACHE_GB:-40}" "$k" >> "$W/dcache_gc.out" 2>&1 & )
    S2A_DIRECT_CACHE=$DCACHE/$k S2A_MAC_SLOT_WAIT_S=600 ${sw[@]+"${sw[@]}"} env -u S2A_SLOT_RUN timeout -k 30 "${CENSUS_LOCAL_S:-${WALL:-4200}}" env $FAB QT_SLOT=census QT_FULL=1 QT_DUAL=1 QT_NATIVE_TIER=${CENSUS_NATIVE_TIER:-1} QT_UNPACK_S="$us" QT_RUN_S="$RUN_S" QT_NAME="$k" S2A_SCREEN_W="$SW" ${PKL:+QT_KEEP=1} \
      bash -c 'bash "$1/tools/quicktest/one_game.sh" "$2" "$3"; rc=$?; bash "$1/tools/census/patch_run.sh" "$2" "$3" "$4"; exit $rc' _ "$R" "$B/$X" "$W/r" "$k" > "$W/run.out" 2>&1; rc=$?
  else
  # 远端直连中间缓存同样常驻：~/.s2arm/run/s2arm/census_dcache/<程序号>，上限 CENSUS_REMOTE_DCACHE_GB（缺省 40，Air）；缓存键跨机一致（73aa6a187），本机出过的款远端也命中
  #   （10-29 曾放远端局工作目录随局删：当时没上限，Air 上单款 du 到 211 GB）
  # 远端满核槽按普查道数给（S2A_REMOTE_SLOTS，缺省 1 = 整台只许一条命令：10-29 实测第 2 道干等第 1 道 500 秒，每台实际只跑 1 款）：
  #   普查自己的各道可以并行，第 2 道起照旧过 lane_ok（远端负载 < 核数、盘过闸）才接；门禁仍按 1 槽排队、优先级更高
  # 远端出包并行度（11-01 总指挥：Air 1 分钟负载冲到 55 把帧率读数拖成假红）：不再固定每道 2 核（只剩一单在出包时 8 核只用 2，勇者斗恶龙 XI 出库 43 分钟），
  #   交给 tools/cores.sh 按同机真实在跑道数分：one_game.sh 把出包 + Mac 局整段登记成一道，4 道都在忙时每道 8÷4 = 2，只有一道时拿满
  # 只拉回日志与结果表（11-02 Air 批：超墙钟 124 时 one_game 来不及清 r/work，整份拉回连解包 + 产物根 22~34 GB 一起落本机，入表后也没人清；普查只读 r/logs 与 r/结果.tsv）
# >>> pulls
  PULLS=(--pull "~/$REL/work/$k/r/logs=$W/r/logs" --pull "~/$REL/work/$k/r/结果.tsv=$W/r/结果.tsv")
# <<< pulls
  # 补丁局（patch_run.sh）：本款有补丁就把 <补丁根>/<程序号>/ 拷进工作目录同步过去（远端补丁根 = 那份），补丁局的日志与结果一并拉回
  local RP= PSYNC=(); if [ -n "${CENSUS_PATCH_DIR:-}" ] && [ -f "$CENSUS_PATCH_DIR/$k/patch.tsv" ]; then
    rm -rf "$W/patch" && mkdir -p "$W/patch" && cp -R "$CENSUS_PATCH_DIR/$k" "$W/patch/" && RP="CENSUS_PATCH_DIR=\$HOME/$REL/work/$k/patch"
    PSYNC=(--sync "~/$REL/work/$k/patch"); PULLS+=(--pull "~/$REL/work/$k/r_patch/logs=$W/r_patch/logs" --pull "~/$REL/work/$k/r_patch/结果.tsv=$W/r_patch/结果.tsv"); fi
  S2A_REMOTE_SLOTS=$RLANES S2A_REMOTE_LONG="普查：远端出包 + Mac 局 $RUN_S 秒" bash "$R/tools/remote.sh" --host "$h" --name "${NAME}_${h}$([ "$ln" = 1 ] || echo "_$ln")" --timeout "${CENSUS_REMOTE_S:-${WALL:-5400}}" \
    $([ "$AIRLOCAL" = 1 ] || echo "--sync ~/$REL/$X") ${PSYNC[@]+"${PSYNC[@]}"} "${PULLS[@]}" -- \
    bash -c "${RSAVE:-}S2A_SAFE_RM=\$HOME/.s2arm/run/s2arm/bin/safe_rm.sh; [ -f \$S2A_SAFE_RM ] || unset S2A_SAFE_RM; export S2A_SAFE_RM; python3 tools/census/dcache_gc.py \"\$HOME/.s2arm/run/s2arm/census_dcache\" ${CENSUS_REMOTE_DCACHE_GB:-40} $k; env ${CENSUS_REMOTE_SLOT_RUN:+S2A_SLOT_RUN=\"$CENSUS_REMOTE_SLOT_RUN\" S2A_SLOTS=1 S2A_SLOT_DIR=\"\$HOME/.s2arm/run/s2arm/slots_census\"} S2A_VISION_PROXY=${CENSUS_VISION_PROXY-http://127.0.0.1:18118} S2A_DIRECT_CACHE=\"\$HOME/.s2arm/run/s2arm/census_dcache/$k\" $FAB QT_SLOT=census QT_FULL=1 QT_DUAL=1 QT_NATIVE_TIER=${CENSUS_NATIVE_TIER:-1} QT_UNPACK_S=$us ${AIRLOCAL:+QT_KEEP_EXEFS=$AIRLOCAL} QT_RUN_S=$RUN_S QT_NAME=$k QT_TITLE_ID=$k S2A_SCREEN_W=$SW bash -c 'bash tools/quicktest/one_game.sh \"\$1\" \"\$2\"; rc=\$?; $RP bash tools/census/patch_run.sh \"\$1\" \"\$2\" $k; exit \$rc' _ \"$([ "$AIRLOCAL" = 1 ] && echo "$AIRSRC/$k" || echo "\$HOME/$REL/$X")\" \"\$HOME/$REL/work/$k/r\"" > "$W/run.out" 2>&1; rc=$?
  fi
  # 接口缺口（11-01 总指挥：常设预检并进普查、不另设门禁步骤）：解包的 exefs 静态读 + 这局 host.log 运行期红行（Slay the Spire 这类按名现查的只在运行期出现）→ $W/api_gap，总表「接口缺口」列
  [ -n "$PKL" ] && [ -d "$PKL" ] && mkdir -p "$W/r/logs/$k" && rsync -a --ignore-existing --exclude=/exefs "$PKL/" "$W/r/logs/$k/"   # 出包段日志并进局日志（局里同名的不盖）
  rm -f "$W/api_gap"; EXD=$W/p/work/$k/extract/exefs; [ -n "$PKL" ] && EXD=$PKL/exefs; [ "$AIRLOCAL" = 1 ] && EXD=$W/r/logs/$k/exefs; [ -d "$EXD" ] && "$PY" "$R/tools/census/api_census.py" "$EXD" --logs "$W/r/logs/$k/host.log" --gap "$W/api_gap" > "$W/api_gap.out" 2>&1
  # Mac 局槽被占（本机 4 个 Mac 局槽被门禁显卡步骤 / 各线健康表占满，进局检查排满 S2A_MAC_SLOT_WAIT_S 秒也没拿到槽）：局根本没起，不是这款的问题。
  #   one_game 照样写出「未判 / 局没起」一行（11-02 泰拉瑞亚连排两次各 ~10 分钟，被记成未判）——识别「结果是未判·局没起 + run_mac.out 里有 Mac 局槽等待行」→ 放回待跑、不计次、这道退避
  if [ -s "$W/r/结果.tsv" ] && awk -F'\t' 'NR > 1 && $4 == "未判" && $5 == "局没起" {f = 1} END {exit !f}' "$W/r/结果.tsv" && grep -a -q 'Mac 局槽：' "$W/r/logs/$k/run_mac.out" 2> /dev/null; then
    log "$k ${nm}（${h}）Mac 局槽被占、局没起，放回待跑（不计次）：$(grep -a 'Mac 局槽：' "$W/r/logs/$k/run_mac.out" | tail -1 | cut -c1-100)"; return 2
  fi
  if [ -s "$W/r/结果.tsv" ] && [ "$(wc -l < "$W/r/结果.tsv")" -ge 2 ]; then CENSUS_PATCH_RES=$([ -s "$W/r_patch/结果.tsv" ] && echo "$W/r_patch/结果.tsv") CENSUS_API_GAP="$W/api_gap" CENSUS_FAIL_LIST="$B/直连编不过清单.tsv" "$PY" "$R/tools/census/census.py" row "$k" "$nm" "$ver" "$h" "$gb" "$W/r/结果.tsv" "$us" >> "$T"
    # 手测队列（11-02 jhz）：出包成功、自动玩家判不出进局（否 / 未判）的款追加进 CENSUS_MANUAL_QUEUE，交体验线装测试机给 jhz 手玩
    [ -n "${CENSUS_MANUAL_QUEUE:-}" ] && "$PY" "$R/tools/census/census.py" manual_queue "$T" "$CENSUS_MANUAL_QUEUE" "$(basename "$B")" "$(git -C "$R" rev-parse --short HEAD)"
    [ "$AIRLOCAL" = 1 ] && [ -n "$AIRSH" ] && air_src_delete "$AIRSH" "$k"   # 判完即删 Air 原件（11-04：不靠外部看守 air_lane_guard）
  elif grep -a -q -E '磁盘不足|排队超' "$W/run.out"; then   # 机器自身原因拒派（盘满 / 满核槽排队超时）：不怪这款，不计次，放回待跑、这台退避
    log "$k ${nm}（${h}）这台拒派，放回待跑（不计次）：$(grep -a -E '🔴|【红】' "$W/run.out" | tail -1 | cut -c1-120)"; return 2
  elif [ "$(cat "$W/attempts" 2> /dev/null || echo 0)" -lt 2 ]; then   # 派出去了但没出结果（超墙钟 / 远端出错）：根留着、放回待跑，别的机器先接；同一款 3 次才记未判
    echo $(( $(cat "$W/attempts" 2> /dev/null || echo 0) + 1 )) > "$W/attempts"
    log "$k ${nm}（${h}）没跑成，放回待跑（第 $(cat "$W/attempts") 次）：$(norun_why)"; return 2
  else   # 同一款连续 3 次没跑成：基础设施问题，记「未判」，下次重跑 census.sh 重排
    printf '%s\n' "$k	$nm	$ver	$h	$gb	-	未判	局没起	$us	0	0	-	-	0	-	-	-	$(norun_why | cut -c1-160 | tr '\t' ' ')	-	$(date +%F)" >> "$T"
  fi
  # 留证款（one_game.sh 写 logs/<键>/.留证：直连异常 / 首帧没出图 / GPU / 出包失败；机器原因的「未判」不留：盘不够时每款留 4~6 GB 会让盘更满、更多款被拒，11-01）：本机那份解包目录留到批次收尾，供画面线 / 出包线复查；其余用完即删（本机盘）；日志在 $W/r
  #   （11-04 总指挥改：判完当场释放大件——包、产物根、解包目录一律删，留证款也只留日志与最小复现件（日志目录里已有 one_game 留的 exefs）；
  #    原先留证款整份解包 + 产物留到收尾，r2 每款 20–50 G、工作盘净降 10 G/分，清理器追不上）
  [ -f "$W/r/logs/$k/.留证" ] && { touch "$W/.留证"; log "$k ${nm}：留证（$(head -1 "$W/r/logs/$k/.留证" | cut -c1-60)），只留日志 + exefs：$W/r/logs/$k"; }
  # CENSUS_KEEP_KEYS=<键,…>（11-05 能耗线：侍魂晓 GPU 缺页要原样复现）：名单里的款判完不释放包与产物根，日志写明路径，用完由要的人删
  #   11-06：保留只靠本函数不删不够——工作盘清理器（tools/ops/work_cleaner.sh 局 work 规则）对已判款只留 r/logs，30 分钟后照删；写 $W/.保留（一行原因）给清理器认
  case ",${CENSUS_KEEP_KEYS:-}," in *",$k,"*) echo "CENSUS_KEEP_KEYS $(date '+%m-%d %H:%M') 包与产物根留给要的人复现，用完由要的人删" > "$W/.保留"
      log "${k} ${nm}：按 CENSUS_KEEP_KEYS 保留包与产物根：${W}/p ${W}/r/work（日志 ${W}/r/logs/${k}；已写 ${W}/.保留，清理器不删）";;
    *) work_rm "$W/p"; work_rm "$W/r/work";; esac
  log "$k ${nm}（${h}，rc=${rc}）：$(tail -1 "$T" | cut -f7,8,19)"
}

# >>> packer（单测 census_test ㊿ / ㊶h 按这两行标记抽出来测）
# packone <键> <名> <版本> <字节> <原件…>：源目录 work/<键>/src 里只放指向原件的软链（不拷贝：原件就是索引表 / --src 目录里的路径），one_game.sh 解包 + 出包
#   （QT_PACK_ONLY=1：① ② 做完写 .qt_packed 就停；prod.keys 只在本机）；解包后删源目录（只删链接）。失败记一行（第一个失败点「解包…」/「出包：…」），成功进 packed/（待跑）。
#   任何一个原件不在 / 链不上 = 整款不解，记未判「机器原因」（资料盘没挂 / 索引表路径失效，不是游戏的问题，下次启动重排）。
#   出包提前到解包工人（11-04 总指挥方案 A：原先出包在跑局道 runone 里、和 Mac 局同一道串行，直连库 Metal 冷编 30–40 分钟把整道停住，本机道 12 款 / 时）：
#   跑局道收到的是出好的工作目录（.qt_packed）只跑局，本机直接用、Air 同步过去。出包口径与 runone 本机段逐项相同（同一组环境变量、机器槽在计时外取、
#   直连缓存 $DCACHE/<键> 先记用过再后台淘汰、墙钟 CENSUS_LOCAL_S；单测 census_test 59 从 runone 源码抽变量集合对比），只多 QT_PACK_ONLY / QT_KEEP_EXEFS
#   （出包后删解包目录前把 exefs 留进日志目录，接口缺口 api_census 读）/ QT_KEEP（出包失败时留工作目录：留证款的解包目录留到批次收尾，同原 runone）
packone() {
  local k=$1 nm=$2 ver=$3 sz=$4 gb W=$B/work/$1 S=$B/work/$1/src f rc t0; shift 4; bat_ok
  gb=$(awk -v b="$sz" 'BEGIN{printf "%.1f", b / 2^30}'); local WALL; WALL=$(wall_s "$gb" 2> /dev/null)
  work_rm "$W"; mkdir -p "$S"
  for f in "$@"; do [ -f "$f" ] && ln -s "$f" "$S/" || {
    work_rm "$W"; log "【红】原件不在 / 链不上，停这一款不解包：$k ${nm}（${f}）"
    printf '结论\t第一个失败点\n未判\t机器原因：原件不在（%s；资料盘没挂 / 索引表路径失效，不是游戏的问题，下次启动重排）\n' "$f" > "$B/.srcfail.$k.tsv"
    CENSUS_FAIL_LIST="$B/直连编不过清单.tsv" "$PY" "$R/tools/census/census.py" row "$k" "$nm" "$ver" 本机 "$gb" "$B/.srcfail.$k.tsv" >> "$T"; rm -f "$B/.srcfail.$k.tsv"
    return; }; done
  # 压缩件（.nsz / .xcz）不先转 nsp / xci（11-01 出包线：外部 nsz 工具转出的副本可能被截断，把好原件记成「源文件坏」；nx_unpack 原生认 .nsz，直接解原件）
  local sw=(); [ -n "${S2A_SLOT_RUN:-}" ] && { read -r -a sw <<< "$S2A_SLOT_RUN"; sw+=("census-$k" --); }
  mkdir -p "$DCACHE/$k" && touch "$DCACHE/$k/.used"
  [ "${DCACHE_GC:-1}" = 1 ] && ( "$PY" "$R/tools/census/dcache_gc.py" "$DCACHE" "${CENSUS_DCACHE_GB:-40}" "$k" >> "$W/dcache_gc.out" 2>&1 & )
  # 本机工作盘准入（11-06：普查本机打包不经 packq 那道准入，c1106_rj1 一款 28G）：one_game 外套 tools/disk_admit.py，排到再打包，结束按 $W/p 实际大小记成本款下次的预计
  t0=$SECONDS; S2A_DIRECT_CACHE=$DCACHE/$k S2A_MAC_SLOT_WAIT_S=600 ${sw[@]+"${sw[@]}"} env -u S2A_SLOT_RUN timeout -k 30 "${CENSUS_LOCAL_S:-${WALL:-4200}}" env $FAB QT_SLOT=census QT_FULL=1 QT_DUAL=1 QT_NATIVE_TIER=${CENSUS_NATIVE_TIER:-1} QT_RUN_S="$RUN_S" QT_NAME="$k" S2A_SCREEN_W="$SW" \
    QT_PACK_ONLY=1 QT_KEEP_EXEFS=1 QT_KEEP=1 QT_TITLE_ID=$k python3 "$R/tools/disk_admit.py" run --cat census --name "$k" --measure "$W/p" -- bash "$R/tools/quicktest/one_game.sh" "$S" "$W/p" > "$W/pack.out" 2>&1; rc=$?
  rm -rf "$S"
  if [ $rc != 0 ]; then
    # 墙钟超时 / 被杀：one_game 来不及写结果行 → 记未判（下次普查重排），不留空（没有这一行总表就少一款、日志里 tail 出的是上一款）
    [ "$(wc -l < "$W/p/结果.tsv" 2> /dev/null || echo 0)" -ge 2 ] || printf '结论\t第一个失败点\n未判\t出包没写出结果行（退出码 %s，实跑 %s 秒，墙钟兜底上限 %s 秒）\n' "$rc" "$((SECONDS - t0))" "${CENSUS_LOCAL_S:-${WALL:-4200}}" > "$W/p/结果.tsv"
    CENSUS_FAIL_LIST="$B/直连编不过清单.tsv" "$PY" "$R/tools/census/census.py" row "$k" "$nm" "$ver" 本机 "$gb" "$W/p/结果.tsv" >> "$T"; log "$k ${nm}：$(tail -1 "$T" | cut -f7,8)"
    # 留证（同 runone）：one_game 写了 .留证 的出包失败留工作目录（解包目录 + 出包中间件）到批次收尾；其余删掉出包工作目录，只留日志
    #   （11-04 总指挥改：留证款也当场删出包工作目录，只留日志与 exefs，见 runone 同处）
    [ -f "$W/p/logs/$k/.留证" ] && { touch "$W/.留证"; log "$k ${nm}：留证（$(head -1 "$W/p/logs/$k/.留证" | cut -c1-60)），只留日志 + exefs：$W/p/logs/$k"; }
    work_rm "$W/p/work"
    return; fi
  cut -f3 "$W/p/work/$k/.qt_packed" > "$W/p/logs/$k/unpack_s"   # 解包秒（runone 交 census.py row 记总表；只出包模式 one_game 不写这份）
  # 只跑局只读 @现行（entry_check 起局前克隆现行快照）：出包各阶段留下的旧版本（root_commit 只留现行 + 上一版，钉住的也留；11-04 丝之歌留了 4 版、各 275 MB，
  #   rsync 不认 APFS 克隆、每版按整份传）删掉，RomFS 存储里没有版本再指向的身份一并删（root_romfs_sweep）、出包进程留下的钉删掉。省本机盘与 Air 同步量
  local O=$W/p/work/$k g c d; g=$(cut -f1 "$O/.qt_packed"); c=$(readlink "$O/roots/$g@现行" 2> /dev/null); c=${c##*/}
  if [ -n "$g" ] && [ -n "$c" ] && [ -d "$O/roots/$c" ]; then
    for d in "$O/roots/$g"@*; do case ${d##*/} in "$g@现行"|"$c") ;; *) work_rm "$d";; esac; done
    S2A_ROOTS=$O/roots root_romfs_sweep "$g" 2> /dev/null; rm -f "$O/roots/.pin.$g@"*; fi
  printf '%s\t%s\t%s\n' "$nm" "$ver" "$gb" > "$W/meta"; touch "$PQ/$k"; log "出包好 $k ${nm}：$(tail -1 "$W/pack.out" | cut -c1-120)"
}
# 天眼道出包（11-05 jhz「重活可以都挪到 windows 上了」，CENSUS_TIANYAN=1 起批时开；Windows 出包线）：领到的款整单交天眼（tools/tianyan_lane.py --census），
#   产物根回传落成 one_game.sh QT_PACK_ONLY=1 同布局（$W/p/work/${k}：roots/<款>@现行 + .qt_packed），之后同本机出包好：写 meta / unpack_s、exefs 留进日志目录、进 packed/。
#   并发 = --packers（同时交天眼的单数）；R 盘余量由天眼道自己登记排队。天眼退 75（不可达 / 环境缺件 / 排队等满）= 记【红】并落回本机 packone 照出（不漏判）；
#   124 / 137 / 143（天眼道进程被外部收掉 / 超时）记「未判 机器原因」；其余非 0 = 天眼上出包失败，记一行「失败  出包（天眼）：<最后一行红>」（同本机出包失败；
#   环境 / 工具缺件的红行再由 census.py pack_machine 改记未判），日志留 $W/p/logs/$k/tianyan/
# >>> packone_tianyan
packone_tianyan() {
  local k=$1 nm=$2 ver=$3 sz=$4 gb W=$B/work/$1 O=$B/work/$1/p/work/$1 rc t0 f; shift 4; bat_ok
  gb=$(awk -v b="$sz" 'BEGIN{printf "%.1f", b / 2^30}')
  for f in "$@"; do [ -e "$f" ] || { packone "$k" "$nm" "$ver" "$sz" "$@"; return; }; done   # 原件不在：交 packone 记「机器原因」，同一处口径
  work_rm "$W"; mkdir -p "$W/p/logs/$k"; t0=$SECONDS
  "$PY" "$R/tools/tianyan_lane.py" --commit "$(git -C "$R" rev-parse HEAD)" --source "$@" --out "$O" --census --batch "${B##*/}" > "$W/pack.out" 2>&1; rc=$?   # 批次名：tianyan_lane.py stop --batch <批次> 只收本批
  [ -d "$O/tianyan" ] && cp -R "$O/tianyan" "$W/p/logs/$k/tianyan" 2> /dev/null
  [ -f "$O/tianyan/direct_fail.tsv" ] && cp "$O/tianyan/direct_fail.tsv" "$W/p/logs/$k/direct_fail.tsv"   # 「直连编不过」列读 logs/<键>/direct_fail.tsv（同本机道 one_game.sh 拷的那份）
  if [ $rc = 75 ]; then log "【红】$k ${nm}：天眼道不可用（$(grep -a -E '【红】' "$W/pack.out" | tail -1 | cut -c1-120)），落回本机出包"; packone "$k" "$nm" "$ver" "$sz" "$@"; return; fi
  if [ $rc != 0 ] || [ ! -f "$O/.qt_packed" ]; then
    # 天眼道进程被外部收掉 / 超时（124 timeout、137 KILL、143 TERM：11-05 另一线重起批时宽 pkill 把本批两单一起杀，记成游戏「失败」）= 机器原因，记未判、下次重排；
    #   环境 / 工具缺件的红行（glslangValidator、DM_OODLE_HOST、rc=75…）由 census.py row 的 pack_machine 统一改记未判
    case $rc in
      124|137|143) printf '结论\t第一个失败点\n未判\t机器原因：天眼出包被外部收掉（rc=%s，%s 秒；不是游戏的问题，下次重排）\n' "$rc" "$((SECONDS - t0))" > "$B/.tyfail.$k.tsv";;
      *) printf '结论\t第一个失败点\n失败\t出包（天眼）：%s\n' "$(grep -a -E '【红】|🔴' "$W/pack.out" | tail -1 | tr '\t' ' ' | cut -c1-160)" > "$B/.tyfail.$k.tsv";;
    esac
    CENSUS_FAIL_LIST="$B/直连编不过清单.tsv" "$PY" "$R/tools/census/census.py" row "$k" "$nm" "$ver" 本机 "$gb" "$B/.tyfail.$k.tsv" >> "$T"; rm -f "$B/.tyfail.$k.tsv"
    log "$k ${nm}：天眼出包失败 rc=${rc}（$((SECONDS - t0)) 秒），日志 $W/p/logs/$k/tianyan"; work_rm "$W/p/work"; return; fi
  cut -f3 "$O/.qt_packed" > "$W/p/logs/$k/unpack_s"
  local g; g=$(cut -f1 "$O/.qt_packed"); [ -d "$O/roots/$g@现行/exefs" ] && cp -R "$O/roots/$g@现行/exefs" "$W/p/logs/$k/exefs" 2> /dev/null   # 同 packone QT_KEEP_EXEFS
  printf '%s\t%s\t%s\n' "$nm" "$ver" "$gb" > "$W/meta"; touch "$PQ/$k"; log "出包好 $k ${nm}（天眼，$((SECONDS - t0)) 秒）：$(tail -1 "$W/pack.out" | cut -c1-120)"
}
# <<< packone_tianyan
# packer <号>：按队列顺序领下一款（mkdir $B/seen/<键> 原子认领，本次运行每款只领一次，几个解包工人不重复）→ packone；队列走完就退出。
#   节流（替代拷贝工的「只领先 LEAD 款」）：待跑 packed/ 满 CENSUS_PACKED_MAX（缺省 = 跑局道数）就先等再领。本机盘上同时在的解包目录
#   ≤ 待跑上限 + 解包路数（各路过闸到 touch 之间可多出 解包路数 − 1）+ 跑局道数，有上界、不会无限解包；不再按盘余量准入（工作盘余量由运维清理器保 ≥200G）。
#   Air 本地化：不在本机解包，领款后过 Air 盘准入（清一轮再判，不够记红跳过、不等）→ 原件 rsync 到 Air → 放行进待跑；推原件只开 1 路（起批处 PACKERS=1，同原拷贝工串行推）
packer() {
  local i=$1 k nm ver base fs sz nz isa fa c0
  while IFS=$'\t' read -r k nm ver base fs sz nz isa <&3; do
    [ "$k" = 键 ] && continue; [ -e "$B/seen/$k" ] && continue
    while [ "$(ls "$PQ" | wc -l)" -ge "${CENSUS_PACKED_MAX:-$LANES}" ]; do sleep 10; bat_ok; done
    mkdir -p "$B/seen"; mkdir "$B/seen/$k" 2> /dev/null || continue   # 别的解包工人刚领走
    bat_ok; IFS='|' read -r -a fa <<< "$fs"
    if [ "$AIRLOCAL" = 1 ]; then
      air_disk_gate "$k" "$nm" "$ver" "$(awk -v b="$sz" 'BEGIN{printf "%.1f", b / 2^30}')" "$(awk -v b="$sz" 'BEGIN{printf "%.1f", b / 2^30}')" || continue   # 清一轮再判盘，不够记红跳过（不等）
      c0=$(date +%s)
      if ! air_push "$AIRSH" "$k" "$sz" "${fa[@]}"; then log "【红】推 Air 失败，停这一款：$k ${nm}"; continue; fi
      work_rm "$B/work/$k"; mkdir -p "$B/work/$k"; printf '%s\t%s\t%s\n' "$nm" "$ver" "$(awk -v b="$sz" 'BEGIN{printf "%.1f", b / 2^30}')" > "$B/work/$k/meta"
      touch "$PQ/$k"; log "放行 $k ${nm}（Air 本地解包）：推原件 $((sz / 1048576)) MB，$(($(date +%s) - c0)) 秒"; continue
    fi
    if [ "${CENSUS_TIANYAN:-0}" = 1 ]; then packone_tianyan "$k" "$nm" "$ver" "$sz" "${fa[@]}"; else packone "$k" "$nm" "$ver" "$sz" "${fa[@]}"; fi
  done 3< "$Q"
  log "出包工人 $i 结束"
}
# <<< packer

lane_ok() {   # lane_ok <机器>：第 2 道起接下一款的门槛——远端 CPU 实际空闲 ≥ S2A_CPU_IDLE_MIN（缺省 15%，与本机同一阈值；remote.sh --idle 打的「CPU 实际空闲 X%」，
  #   连不上算不过；10-29 不再看 load average）且盘过远端硬闸（--disk）
  local h=$1 o i; o=$(S2A_REMOTE_IDLE_NOSLOT=1 S2A_REMOTE_IDLE_PCT=0 bash "$R/tools/remote.sh" --host "$h" --idle 2> /dev/null) || return 1   # 只看 CPU：本批自己的第 1 道占着满核槽是常态
  i=$(printf '%s' "$o" | sed -n 's/.*CPU 实际空闲 \([0-9]*\)%.*/\1/p'); [ -n "$i" ] && [ "$i" -ge "${S2A_CPU_IDLE_MIN:-15}" ] || return 1
  S2A_REMOTE_DISK_SUB=home/.s2arm/run/s2arm/census bash "$R/tools/remote.sh" --host "$h" --disk > /dev/null 2>&1
}
# >>> disk_ok（单测 census_test ㉟ 按这两行标记抽出来测）
# disk_ok <机器> <键>：远端可用 − 这款预估峰值 ≥ 远端硬闸（S2A_REMOTE_MIN_FREE_GB，缺省 20）才接（每道都判）。
#   预估峰值 = 4.5 × 源 GB + 14（S2A_REMOTE_EST_R / S2A_REMOTE_EST_C 可改）：11-01 拿 Air 上 8 款实际占用（解包副本 + 出包产物 + 直连缓存，在跑时量的下界）对源大小拟合
#   ≈ 4.4 × 源 + 2，取上包络（勇者 XI S 源 14.2 GB 占 64.5、FINAL FANTASY 源 8.6 GB 占 51.8、Sifu 7.3 占 39.3、泡姆泡姆 4.2 占 21.1、DOUBLE DRAGON4 0.1 占 4.5）；
#   旧公式 3 × 源 + 5 对中大款低估（FINAL FANTASY 估 31 实占 52，Air 因此从 54 GB 一路写到 15 GB）。
#   判不过不再静默空等（11-01 马车8 在 Air 55~72 GB 下被旧闸静默拦了 2.5 小时）：第一次判不过、之后每 10 分钟记一行【黄】「等盘：可用 X / 需 Y」，
#   连续等待超 30 分钟写【红】并调告警钩子 CENSUS_ALERT_CMD；判过就写「盘已够」行并清这款的等待记录
disk_ok() {   # 量远端普查工作目录所在卷（11-02：Air 的工作目录软链到 Air 2T，原先量远端根 = 内置盘 139G，怪猎 31GB 源要 174G 卡等盘）
  local h=$1 gb f e need w
  gb=$(cut -f3 "$B/work/$2/meta" 2> /dev/null); gb=${gb:-1}
  f=$(S2A_REMOTE_DISK_SUB=home/.s2arm/run/s2arm/census bash "$R/tools/remote.sh" --host "$h" --disk 2> /dev/null | sed -n 's/.*可用 \([0-9]*\) G.*/\1/p'); [ -n "$f" ] || return 1
  e=$(awk -v g="$gb" -v r="${S2A_REMOTE_EST_R:-4.5}" -v c="${S2A_REMOTE_EST_C:-14}" 'BEGIN{printf "%d", r * g + c + 0.999}'); need=$((e + ${S2A_REMOTE_MIN_FREE_GB:-20}))
  w="$B/.wait_disk.$h.$2"
  if [ "$f" -ge "$need" ]; then _wait_done "$w" "$h 盘 ${2}（可用 ${f} G）"; return 0; fi
  _wait_tick "$w" "$h 可用 ${f} G / 需 ${need} G（${2} 源 ${gb} GB，预估峰值 ${e} G + 硬闸 ${S2A_REMOTE_MIN_FREE_GB:-20} G）"
  return 1
}
# <<< disk_ok

# >>> local_slot_free（单测 census_test ㉘ 按这两行标记抽出来测）
# 本机机器槽有没有空位：没设 S2A_SLOT_RUN（不走槽）当有；槽目录 <运行区>/slots/<k>（与 slot.sh 同）不存在、或 pid 文件里的进程已退出 = 空位
local_slot_free() {
  [ -n "${S2A_SLOT_RUN:-}" ] || return 0
  local d=${S2A_SLOT_DIR:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/slots} k p
  for k in $(seq 1 "${S2A_SLOTS:-3}"); do
    [ -d "$d/$k" ] || return 0
    p=$(cat "$d/$k/pid" 2> /dev/null); { [ -n "$p" ] && kill -0 "$p" 2> /dev/null; } || return 0
  done; return 1; }
# <<< local_slot_free
# >>> host_build
# 本机宿主编译串行（11-02 v2 本机 3 道同时起，各自 make host，在同一棵树里抢 rm build/s2arm-host.dSYM：make 失败并删掉宿主，一道直接「本机不跑局」）；
#   11-03 一次成功线：锁与构建配置都要和起局的 tools/entry_check.sh 一致——原先锁放在批次目录（同一棵树上两个批次互不相锁）、make 不带 S2A_CS：
#   Makefile 构建配置戳含 S2A_CS，另一批起批时编出「没链 C#」的宿主，盖掉本批正要起局的那份（c1103_recheck4 火炬3、recheck5b 激战前锋、
#   kr_guestlog 假面骑士三局 host.log「S2A_Init：没链 C#」，进 C# 的系统调用 0x1f 全报未实现、判成首帧失败 / 超墙钟）。
#   现在：整棵树一把锁 build/.make_host.lock（同 entry_check，最多等 600 秒），S2A_CS=1；先到的编完，后到的 make 是空操作（秒回）
host_build() {
  bash "$R/tools/host_build.sh" > "$B/local_host_build.log" 2>&1   # 11-04：锁 / S2A_CS 统一收进 tools/host_build.sh
}
# <<< host_build
# >>> runner_wait（单测 census_test ㊻ 按这两行标记抽出来测）
# 跑局道静默等待要出声（11-04 压测：本机暂停旗遗留，4 道每 20 秒空转 45 分钟、日志 0 行、没人报）：
#   rwait <状态文件> <原因>：进入等待或原因变了 → 写一行【黄】；同一原因连等满 CENSUS_WAIT_RED_S（缺省 1800 秒）→ 写一行【红】（每段只一次）
#   rwait_end <状态文件>：领到款，写一行「不再等待」并清状态（没等过就静默）
rwait() {
  local f=$1 why=$2 now t0 old red
  now=$(date +%s)
  if [ -f "$f" ]; then IFS=$'\t' read -r t0 old red < "$f"; else t0=$now; old=; red=0; fi
  if [ "$old" != "$why" ]; then t0=$now; red=0; log "【黄】跑局道等待：${why}"; fi
  if [ $((now - t0)) -ge "${CENSUS_WAIT_RED_S:-1800}" ] && [ "$red" = 0 ]; then red=1; log "【红】跑局道已等 $(( (now - t0) / 60 )) 分钟：${why}"; fi
  printf '%s\t%s\t%s\n' "$t0" "$why" "$red" > "$f"
}
# local_paused：本机道暂停旗有主才算数（11-04 压测：凌晨挂的空旗主人早没了，4 道静默空转 45 分钟）。
#   旗文件内容 = 挂旗进程的 pid（挂法：echo <活着的 pid> > 旗）；进程活着 → 暂停（返回 0）；空文件 / 进程不在 → 写一行【红】「遗留暂停旗无主」、删旗、不暂停
local_paused() {
  local f=${S2A_CENSUS_LOCAL_PAUSE:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/locks/census_local_pause} p
  [ -e "$f" ] || return 1
  p=$(head -1 "$f" 2> /dev/null | tr -cd '0-9')
  [ -n "$p" ] && kill -0 "$p" 2> /dev/null && return 0
  rm -f "$f" && log "【红】本机暂停旗 $f 无主（内容「${p:-空}」，挂旗进程不在），已删、不暂停；要暂停请写入挂旗进程 pid"
  return 1
}
rwait_end() { [ -f "$1" ] || return 0; log "跑局道不再等待（原因：$(cut -f2 "$1")，等了 $(( ($(date +%s) - $(cut -f1 "$1")) / 60 )) 分钟）"; rm -f "$1"; }
# <<< runner_wait
# >>> claim
# claim <机器> <键>：从待跑认领到 running/，文件内容写机器名（air_mem_ok 只数本机器的）；保留原时间戳，退避放回后排序不变
claim() { local f=$B/running/$2 t; mv "$PQ/$2" "$f" 2> /dev/null || return 1; t=$(stat -f %Sm -t %Y%m%d%H%M.%S "$f"); echo "$1" > "$f"; touch -t "$t" "$f"; }
# <<< claim
runner() {   # runner <机器> [道]：取最早出好的一款（mv 到 running/ 认领）→ runone；出包全部结束且待跑空就退出。第 2 道起每款先过 lane_ok，不过等 60 秒再看
  local h=$1 k ln=${2:-1} why anm aver agb RW=$B/.rwait.$1.${2:-1}
  if [ "$h" = local ]; then   # 本机先把宿主编好再拿局槽（10-29 Snipperclips：第一局现编宿主吃满 335 秒局槽，游戏正常收局却被超时杀、记成崩溃）
    host_build || { log "【红】本机宿主编不出来（$B/local_host_build.log），本机不跑局"; return; }
  fi
  while :; do k=$(ls -tr "$PQ" 2> /dev/null | head -1)
    if [ -z "$k" ]; then [ -f "$B/.pack_done" ] && break; sleep 10; continue; fi
    # 本机先看机器槽有空位再领款（10-31：3 槽被出包实验单占满时，本机 3 道把待跑款全领走、各自在 slot.sh 里干等 36 分钟，Air 道一直领不到款闲着）
    # 本机道暂停旗（11-01 总指挥：体验线判帧率的局要低负载）：有主的旗在就不接新款，在跑的局不动；撤旗或挂旗进程退出即恢复（local_paused）。旗 = ${S2A_CENSUS_LOCAL_PAUSE} 缺省 ~/.s2arm/run/s2arm/locks/census_local_pause
    [ "$h" = local ] && local_paused && { rwait "$RW" "本机 ${ln} 道：暂停旗在（挂旗进程 $(head -1 "${S2A_CENSUS_LOCAL_PAUSE:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/locks/census_local_pause}" 2> /dev/null) 活着；撤旗或它退出即恢复）"; sleep 20; continue; }
    [ "$h" = local ] && ! local_slot_free && { rwait "$RW" "本机 ${ln} 道：机器槽没有空位"; sleep 15; continue; }
    # 本机负载过高不接新款（11-01 总指挥：本机路在 1 分钟负载 > CENSUS_LOCAL_LOAD_MAX（缺省 36）时停接，已在跑的不动）
    [ "$h" = local ] && [ "$(sysctl -n vm.loadavg | awk '{print int($2)}')" -gt "${CENSUS_LOCAL_LOAD_MAX:-36}" ] && { rwait "$RW" "本机 ${ln} 道：1 分钟负载 > ${CENSUS_LOCAL_LOAD_MAX:-36}"; sleep 60; continue; }
    rwait_end "$RW"
    [ "$ln" = 1 ] || [ "$h" = local ] || lane_ok "$h" || { sleep 60; continue; }   # 第 2 道：远端负载 / 盘不过就这轮不接（= 退回 1 道），不用来问
    if [ "$h" = air ] && [ "$AIRLOCAL" = 1 ]; then   # Air 道（11-04 复核）：盘不走 disk_ok 等盘循环；第 2 道起先过内存准入
      if [ "$ln" != 1 ] && ! why=$(air_mem_ok "$AIRSH" "$ln"); then   # 不过 = 这轮不接（只开 1 道，不交换）；黄行 10 分钟最多一条
        [ -n "$(find "$B" -maxdepth 1 -name ".memwait.$ln" -mmin -10 2> /dev/null)" ] || { log "【黄】Air 第 ${ln} 道这轮不接（内存准入不过，只开 1 道）：$why"; touch "$B/.memwait.$ln"; }
        sleep 60; continue; fi
      claim "$h" "$k" || continue
      IFS=$'\t' read -r anm aver agb < "$B/work/$k/meta"
      # 开跑前清一轮再判盘（原件已在 Air 上，待推 0）；不够 → 记红跳过、删这款 Air 原件，不 sleep 重试
      air_disk_gate "$k" "$anm" "$aver" "$agb" 0 || { rm -f "$B/running/$k"; air_src_delete "$AIRSH" "$k"; continue; }
    else
      [ "$h" = local ] || disk_ok "$h" "$k" || { sleep 60; continue; }   # 远端每道按这款预估判盘
      claim "$h" "$k" || continue
    fi
    runone "$h" "$k" "$ln"
    if [ $? = 2 ]; then mv "$B/running/$k" "$PQ/$k"; log "跑局工人 $h#$ln 退避 ${CENSUS_BACKOFF_S:-600} 秒"; sleep "${CENSUS_BACKOFF_S:-600}"   # 放回（保持原时间戳，别的工人先接）；本机器先歇
    else rm -f "$B/running/$k"
      # 每款记表后重出直连缺陷表（10-30 任务书：缺陷表随普查更新；一批几小时，各线按这张表派单，不等批末 sum）
      # 缺陷表随普查更新，但不每款重读整张总表 + 逐款日志（审计 P1-57：一批 200 款 = 重读 200 遍）：距上次出表不足 CENSUS_DEFECTS_EVERY_S（缺省 300）秒就跳过，批末 census.py sum 还会再出一次
      if [ -z "$(find "$B" -maxdepth 1 -name '直连缺陷表.tsv' -mmin "-$(( ${CENSUS_DEFECTS_EVERY_S:-300} / 60 ))" 2> /dev/null)" ]; then
        "$PY" "$R/tools/census/census.py" direct_defects "$B" "$R" > /dev/null 2>> "$L" || log "【黄】$k 记表后重出直连缺陷表失败（错误见上）"; fi
    fi
  done
  log "跑局工人 $h#$ln 结束"
}

# 被停时连后台的解包工人 / 跑局工人与它们起的 remote.sh、one_game 一起停（10-29：只停主进程留下 38 个孤儿进程）
trap 'trap - TERM INT; log "收到停止，停整个进程组"; [ "$AIRLOCAL" = 1 ] && [ -n "${AIRSH:-}" ] && air_src_purge "$AIRSH"; kill 0' TERM INT
s0=$(date +%s); log "开跑：$n 款排队"
rm -f "$B/.pack_done"
for k in $(ls "$B/running"); do mv "$B/running/$k" "$PQ/$k"; done   # 上次中断时在跑的款重新排到待跑
rm -rf "$B/seen"; mkdir -p "$B/seen"   # seen 只管本次运行（解包工人领款记号）；跨重启靠总表 + 排队；上次解到一半的款没进待跑，本次重领重解（packone 先清工作目录）
for k in $(ls "$PQ"); do mkdir "$B/seen/$k"; done   # 已解包待跑的款：不再解
RLANES=${CENSUS_REMOTE_LANES:-3}   # 远端每台道数（10-29 出包线：出包挪到远端后每款远端要 出包 + 局 ≈ 12–20 分钟，3 道 × 2 台 + 本机 1 道才够 30 款 / 小时）
LLANES=${CENSUS_LOCAL_LANES:-2}   # 本机道数（10-29 出包线：c1029c 实测远端 CPU 压满时本机负载只 9–28，本机 2 道才够 30 款 / 小时；出包段走本机机器槽）
# 门禁专用机（tools/remote.sh --gate-only，10-30 jhz 批 mini 专给列车门禁）不进本批：不开道、不按它的道数预取原件（10-30 c1029c 拷贝工按含 mini 的道数多预取了几款）
HK=; IFS=, read -r -a HS0 <<< "$HOSTS"; for h in "${HS0[@]}"; do
  if [ "$h" != local ] && bash "$R/tools/remote.sh" --host "$h" --gate-only > /dev/null 2>&1; then log "【黄】$h 是门禁专用机，本批不派"; continue; fi
  HK="${HK:+$HK,}$h"; done; HOSTS=$HK; [ -n "$HOSTS" ] || { log "🔴 去掉门禁专用机后没有跑局机器"; exit 2; }
IFS=, read -r -a HS <<< "$HOSTS"; LANES=0; for h in "${HS[@]}"; do [ "$h" = local ] && LANES=$((LANES + LLANES)) || LANES=$((LANES + RLANES)); done   # 跑局道数：远端每台 RLANES、本机 LLANES
# 汇总.md 跟着跑：原先只在批次结束时重算一次，跑几小时的批次汇总一直停在开头（11-02 汇总写 20 款、总表已 39 行，读的人被误导）→ 每 CENSUS_SUM_EVERY_S（缺省 900）秒重算一次
sum_live() { while [ -e "$B/.census_batch" ]; do sleep "${CENSUS_SUM_EVERY_S:-900}"; "$PY" "$R/tools/census/census.py" sum "$B" > /dev/null 2>&1; done; }
sum_live & SUMLIVE=$!
# 批次停摆看守（11-04 压测：45 分钟 0 行没人报）：批次日志 CENSUS_STALL_RED_S（缺省 1800 秒）没新行就写一行【红】，带各跑局道在等什么；写红本身算新行，之后每 30 分钟再报
# >>> stall_watch
# 出包中的款（11-05 c1105_ty12：两次报「待跑 0、在跑 0」看似空转，实为两单在天眼——一单排盘位挂 2 小时、一单传原件 1 小时）：
#   本次领过（seen/）、还没进待跑 / 在跑、总表也没有行的款 = 出包工人手上的，各带出包日志末行
stall_packing() { local k n=0 o=; for k in $(ls "$B/seen" 2> /dev/null); do
    [ -e "$PQ/$k" ] || [ -e "$B/running/$k" ] && continue; [ -n "${T:-}" ] && grep -q "^$k	" "$T" 2> /dev/null && continue
    n=$((n + 1)); o="$o${k}（$(tail -1 "$B/work/$k/pack.out" 2> /dev/null | cut -c1-80)）；"; done; echo "出包中 $n 款：${o:-无}"; }
stall_watch() { while [ -e "$B/.census_batch" ]; do sleep "${CENSUS_STALL_EVERY_S:-300}"
  [ $(( $(date +%s) - $(stat -f %m "$L" 2> /dev/null || date +%s) )) -ge "${CENSUS_STALL_RED_S:-1800}" ] || continue
  log "【红】批次 $(( ${CENSUS_STALL_RED_S:-1800} / 60 )) 分钟没有新行：待跑 $(ls "$PQ" 2> /dev/null | wc -l | tr -d ' ')、在跑 $(ls "$B/running" 2> /dev/null | wc -l | tr -d ' ')；$(stall_packing)；跑局道在等：$(cat "$B"/.rwait.* 2> /dev/null | cut -f2 | tr '\n' ';')"; done; }
# <<< stall_watch
stall_watch & STALLW=$!
# 远端出包段串行（11-02 总指挥：dsh_batch 单进程内存随着色器键数涨到 50 GB 级，Air 只有 16 GB，多道同时出包会 Jetsam）：
#   设 CENSUS_REMOTE_SLOT_RUN（远端能执行的 slot.sh run 命令）→ 远端每道的 one_game 出包段前套 S2A_SLOT_RUN、槽数 1，出包串行、跑局仍并行；不设 = 照旧。
# Air 路本地化只在「纯 air 批」（--hosts 只有 air）里生效；混了 local 就关（本机路仍本机解包）
[ "$AIRLOCAL" = 1 ] && { [ "$HOSTS" = air ] || AIRLOCAL=0; }
AIRSH=; [ "$AIRLOCAL" = 1 ] && { AIRSH=$(bash "$R/tools/remote.sh" --host air --host 2> /dev/null | tail -1); [ -n "$AIRSH" ] || { log "🔴 取不到 Air 的 ssh 目标，Air 本地化关闭"; AIRLOCAL=0; }; }
AIRMETRICS=; [ "$AIRLOCAL" = 1 ] && { air_metrics_sampler & AIRMETRICS=$!; }   # Air 指标每分钟一行（要 AIRSH，放在它定下之后）
[ "$AIRLOCAL" = 1 ] && PACKERS=1   # Air 本地化不在本机解包，解包工人只推原件：1 路串行推（同原拷贝工），Air 盘准入一次只判一款、不互相漏算待推原件
PKS=(); for ((i = 1; i <= PACKERS; i++)); do packer "$i" & PKS+=($!); done
RNS=(); for h in "${HS[@]}"; do runner "$h" 1 & RNS+=($!); n=$RLANES; [ "$h" = local ] && n=$LLANES
  for ((j = 2; j <= n; j++)); do runner "$h" "$j" & RNS+=($!); done; done
wait "${PKS[@]}"; touch "$B/.pack_done"; log "出包全部结束"
# >>> batch_end
wait "${RNS[@]}"; kill "$SUMLIVE" "${STALLW:-}" 2> /dev/null; [ "$AIRLOCAL" = 1 ] && air_batch_end   # 先停 Air 采样器并出汇总，再 wait（采样器不停 wait 会一直等）
wait; log "全部结束，墙钟 $(($(date +%s) - s0)) 秒"
# <<< batch_end
"$PY" "$R/tools/census/census.py" sum "$B" | tee -a "$L"
# 收批登记（11-02 总指挥 / 运维线定）：逻辑速度同局 A/B、原生 60、直连实测、宽屏两侧缺渲染四类按款登记表写进专用登记树（不是本工作树：它要保持干净给 remote.sh），
#   有新登记就提交一支 census-reg/<批次>-<时刻> 入列车（tools/census/reg.sh）。失败只记一行红、不改批次退出码；CENSUS_REG=0 不做
[ "${CENSUS_REG:-1}" = 0 ] || bash "$R/tools/census/reg.sh" "$B" 2>&1 | tee -a "$L"
