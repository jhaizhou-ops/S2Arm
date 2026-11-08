#!/bin/bash
# Mac 健康表·采集（底本旧库 tools/nine_health.sh @ed859e5）：tools/mac_health.sh <结果目录> [款…]
# 缺省全能力：屏宽 2346 + S2A_WIDEN_CAPS=1；HEALTH_NATIVE=1 才按原比例 16:9。HEALTH_EXTEND=<秒>（缺省 0）：局时顺延上限，自动玩家等视觉模型的秒数不算局时（宿主 S2A_RUN_EXTEND_MAX），墙钟上限同步加。
# 用本代码树的 Mac 入口跑各款一局（缺省九款同时起，HEALTH_PAR 可改；每局游戏 HEALTH_SEC 秒（缺省 280），墙钟硬上限 = 局时 + 10 秒 + 顺延，缺省 290 秒），零专用配置：通用自动玩家（AI 看屏驾驶）。
# Mac 入口（原生层线维护，契约 tests/真机契约.md 第 6 节）：runtime/run_mac.sh <款> <局目录> <秒> —— 局目录里写 host.log、frames.tsv（同真机契约），
#   输入取 <产物根>/<款>/（HEALTH_ROOT，缺省 ~/.s2arm/run/s2arm/roots/<款>@现行）。
# 输入冻结：起局前把该款产物整目录 clonefile 成本局快照（tools/clonedir.py，出包会原地切换产物根），局里只读快照，局末删。
# 对比：tools/health_table.py <基线目录> <候选目录>，任何一款变差退出码 1。
set -u
D=${1:?结果目录}; shift; GS=${*:-acnh mk8d d2r botw d3 witcher3 silksong mhrise octopath2 xc3}
R=$(cd "$(dirname "$0")/.." && pwd); cd "$R"; mkdir -p "$D"; echo "${HEALTH_COMMIT:-$(git rev-parse --short HEAD 2>/dev/null)}" > "$D/commit"
RUN=$R/runtime/run_mac.sh; export S2A_COST_BY_CALLER=1   # 本脚本每款自己记成本账本，run_mac.sh 不重记
source "$R/tools/cost_log.sh"
export S2A_CS=${S2A_CS:-1}   # run_mac.sh 里 make host 要链 C#（服务 + Ryujinx + 渲染器）：不带时 S2A_Init 报「没链 C#」、0x1f 全报未实现，读数作废（10-20 健康表局实测）
[ -f "$RUN" ] || { echo "🔴 没有 Mac 入口 runtime/run_mac.sh（原生层线，契约见 tests/真机契约.md 第 6 节），健康表跑不了"; exit 2; }
# 宿主在局槽外先编好一次（同 tools/entry_check.sh）：局里 run_mac.sh 带 S2A_HOST_PREBUILT=1 不再 make，局槽墙钟只算游戏局；
#   HEALTH_PAR > 1 时几局也不再各自并行 make 抢写同一份构建产物
bash "$R/tools/host_build.sh" > "$D/build.out" 2>&1 || { echo "🔴 宿主构建失败（见 $D/build.out）"; exit 2; }
export S2A_HOST_PREBUILT=1
root() { local v=HEALTH_ROOT_$1; [ -n "${!v:-}" ] && { echo "${!v}"; return; }; (cd -P "${HEALTH_ROOT:-$HOME/.s2arm/run/s2arm/roots}/$1@现行" 2>/dev/null && pwd); }
one() {
  local g=$1 o src sn rc t0=$SECONDS; o=$D/$g; rm -rf "$o"; mkdir -p "$o"
  local hv=HEALTH_ROOT_$g   # 用现行产物根时先刷到本树的阶段键（落后的产物根起局会卡死，读数作废）；显式给了产物根的原样用
  if [ -z "${!hv:-}" ] && [ -z "${HEALTH_ROOT:-}" ] && [ -n "$(root "$g")" ] && { bash "$R/pack/refresh.sh" "$g" > "$o/refresh.log" 2>&1; rc=$?; [ $rc != 0 ] && [ $rc != 3 ]; }; then   # 3 = 通用齐、直连库没出（refresh.sh）
    echo "现行产物根刷新红：$(tail -1 "$o/refresh.log")" > "$o/skip"; echo "[$(date +%T)] 🔴 $g 跳过：$(cat "$o/skip")"; return; fi
  src=$(root "$g"); [ -n "$src" ] && [ -d "$src" ] || { echo "没有 $g 的现行产物根" > "$o/skip"; echo "[$(date +%T)] $g 跳过：没有现行产物根"; return; }
  sn=$o/in_snap; python3 "$R/tools/clonedir.py" "$src" "$sn" || { echo "[$(date +%T)] 🔴 $g 快照失败"; return; }
  local sa; sa=${S2A_SAVES:-$HOME/.s2arm/run/s2arm/saves}/${g}_$(xxd -s 0x40 -l 16 -p "$sn/exefs/main" 2>/dev/null)   # 测试资产存档（按 main 构建号），有就带存档起局
  unset S2A_SAVE_DIR S2A_SYSTEM_TIME   # 存档交给 runtime/run_mac.sh 缺省（tools/mac_save.sh：按同一构建号取存档、拷副本到局目录，原件只读；10-24 前这里直接给原件路径）
  [ -s "$sa/language" ] && export S2A_SYSTEM_LANGUAGE=$(cat "$sa/language") || unset S2A_SYSTEM_LANGUAGE; [ -s "$sa/region" ] && export S2A_REGION=$(cat "$sa/region") || unset S2A_REGION
  [ -s "$sa/timezone" ] && export S2A_TIMEZONE=$(cat "$sa/timezone") || unset S2A_TIMEZONE   # 设备时区（与对拍真值同一份资产，动森岛上时钟按它走）
  # 每局私有的 Ryujinx 数据目录与 Metal 着色器缓存（放局目录下，随局目录清）：缺省共用 ~/Documents/S2A/ryujinx，并行起几款时互踩系统存档、S2A_Init 失败
  #   （10-20 服务接入线并行三款实测）；共用 gal 缓存还会让下一局报「着色器缓存与包不一致：整份换成包内的」。调用方显式给了就照用
  mkdir -p "$o/ryu" "$o/gal"
  # 缺省全能力（11-01 总指挥：验收 / 复判 / 健康局不设就按 2346 宽 + 满屏能力开，五问满屏格才作数；census-not-full-caps-1029 同一老坑）：
  #   屏宽 HEALTH_SCREEN_W（缺省 2346），满屏能力 S2A_WIDEN_CAPS（缺省 1）；只有显式 HEALTH_NATIVE=1 才按原比例 16:9（1920、不开满屏）
  local sw=${HEALTH_SCREEN_W:-2346} wc=${S2A_WIDEN_CAPS:-1}; [ "${HEALTH_NATIVE:-0}" = 1 ] && { sw=1920; wc=0; }
  env S2A_SCREEN_W=$sw S2A_WIDEN_CAPS=$wc S2A_RUN_EXTEND_MAX=${HEALTH_EXTEND:-0} S2A_RYU_DATA=${HEALTH_RYU_DATA:-$o/ryu} NXGAL_SHADER_CACHE_DIR=${HEALTH_GAL_CACHE:-$o/gal} S2A_IN=$sn bash "$R/tools/mac_slot_frozen.sh" run "健康表 $g" $((${HEALTH_SEC:-280} + 10 + ${HEALTH_EXTEND:-0})) -- bash "$RUN" "$g" "$o" "${HEALTH_SEC:-280}" > "$o/run.out" 2>&1; rc=$?   # 上限随局时走（11-01 原写死 290 + 顺延：给 HEALTH_SEC=900 的异度3 局在 590 秒被掐、离 MARK 差几百帧）；排队不计入（10-21：让门禁显卡步骤时局没起就超时）
  chmod -R u+w "$sn" 2> /dev/null; rm -rf "$sn"; echo "[$(date +%T)] $g rc=$rc $(tail -1 "$o/run.out" | cut -c1-120)"
  python3 "$R/tools/zero_gate.py" "$o" > "$o/zero.txt" 2>&1; echo "[$(date +%T)] $g $(cut -c1-300 "$o/zero.txt")"   # 必须为 0 的计数：非 0 当场点名（C 类：漏项出包后第一局就暴露）
  cost_log mac "$g" $((SECONDS - t0)) "rc=$rc $(tail -1 "$o/run.out" | cut -c1-80)" "$o"   # 成本账本（线 / 为什么：调用方 export COST_LINE / COST_WHY）
}
P=${HEALTH_PAR:-9}; set -- $GS
while [ $# -gt 0 ]; do n=0; while [ $# -gt 0 ] && [ $n -lt "$P" ]; do one "$1" & shift; n=$((n + 1)); done; wait; done
echo "全部结束 $(date +%T)（$(cat "$D/commit")，结果 ${D}）"; touch "$D/done"
