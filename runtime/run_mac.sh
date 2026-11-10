#!/bin/bash
# Mac 入口（测试层契约 tests/真机契约.md 第 6 节）：runtime/run_mac.sh <款> <局目录> <秒>
# 输入 S2A_IN（产物根快照，只读）：里面有改写器产物（<模块>.patched.bin / .fixups.tsv / .gates.tsv）与 main.npdm 就直接用；
#   只有原版 exefs/（NSO + main.npdm）时，在 <局目录>/mods 里现改写（runtime/rewriter，单模块 ≤600 秒）。
# 局目录写 host.log（宿主 stderr）；frames.tsv 由渲染器按 S2A_FRAMES_TSV 写（帧率能耗线）。到秒数宿主自行优雅收局（S2A_RUN_S），退出码 0 = 正常收局。
# 调用方要「排队不计入局时限」：bash "维护方工具" run <名> <局时限> -- bash runtime/run_mac.sh …（S2A_MAC_SLOT_HELD=1，本脚本不再拿槽）
# 起宿主带墙钟上限（秒数 + 30 + 局时顺延上限 S2A_RUN_EXTEND_MAX）与内存上限（S2A_MEM_MB，缺省 16384 MB，超即杀并判红）。
#   内存按物理足迹判（tools/phys_footprint.py，proc_pid_rusage ri_phys_footprint），与 iOS 判杀同口径；11-01 前按 ps rss，文件映射的干净页也算进去，
#   无主之地3 直连库段改只读映射后 rss 照样 5.25 GB 被杀而足迹不超（原生崩溃线，维护者定）。取不到足迹时退回 rss 并在红字里注明
set -u
G=${1:?款}; D=${2:?局目录}; SEC=${3:?秒}; IN=${S2A_IN:?S2A_IN=<产物根快照>}
# 工作盘准入（11-06 维护者：录帧每帧一份约 2 GB 的 mem.bin，只在带 S2A_FRAME_REC 录帧时排同一本账；平常 Mac 局写得少，不占预留）
if [ -n "${S2A_FRAME_REC:-}" ]; then . "$(cd "$(dirname "$0")/.." && pwd)/tools/disk_admit_gate.sh"; disk_admit_gate 录帧 "rec_$G" "${S2A_FRAME_REC##*:}" "$0" "$@"; fi
ROOT=$(cd "$(dirname "$0")/.." && pwd); PY=${S2A_PY:-$(bash "$ROOT/tools/machine.sh" get S2A_PY 2> /dev/null)}; PY=${PY:-$(command -v python3)}   # 开发机钉版 venv 在 tools/machine.local 声明
# 先拒绝异链，避免改写、准备存档、拿槽后才发现库读不了；专测回退须显式 S2A_ALLOW_CHAIN_MISMATCH=1。
"$PY" -B "$ROOT/tools/mac_chain_check.py" "${S2A_GAME_DATA:-$IN}" || exit 1
mkdir -p "$D"
if ls "$IN"/*.patched.bin > /dev/null 2>&1; then MODS=$IN
elif [ -d "$IN/exefs" ]; then
  MODS=$D/mods; mkdir -p "$MODS"; REW=$("$PY" "$ROOT/pack/rewriter.py" c-path) || { echo "🔴 $G 取不到 C 改写器（pack/rewriter.py c-path）"; exit 1; }
  for f in "$IN"/exefs/*; do m=$(basename "$f"); case $m in main|sdk|subsdk[0-9]) ;; *) continue;; esac   # Horizon 装载器认的模块名（同 pack/stage_rewrite.sh；逆转裁判456 exefs 里有文本 main.moduleconfig）
    timeout 600 "$REW" "$f" "$MODS" "$m" > "$MODS/$m.rewrite.log" 2>&1 || { echo "🔴 $G 改写 $m 失败（见 $MODS/$m.rewrite.log）"; exit 1; }
  done
  cp "$IN/exefs/main.npdm" "$MODS/"
  "$PY" "$ROOT/graphics/nvn/games/profile_guess.py" --gpu-drivers "$IN/exefs" > "$MODS/gpu_drivers.tsv" || { echo "🔴 $G 判 GPU 驱动模块失败"; exit 1; }   # 直连跳过的驱动模块（同 pack/stage_rewrite.sh）
else echo "🔴 ${G}：S2A_IN=$IN 里既没有改写产物也没有 exefs/"; exit 1; fi
# S2A_HOST_PREBUILT=1：调用方已在局时限外编好宿主（维护方 entry_check.sh），这里不再 make（10-29 本机：多棵工作树共用 NativeAOT 缓存，
#   排局槽空档里别的工作树一编，这里的 make 就重新链接，几十秒算进局时，游戏正常收局却被 335 秒局槽杀、记成偶发崩溃）
if [ "${S2A_HOST_PREBUILT:-}" = 1 ]; then [ -x "$ROOT/build/s2arm-host" ] || { echo "🔴 S2A_HOST_PREBUILT=1 但没有 $ROOT/build/s2arm-host"; exit 1; }
else bash "$ROOT/tools/host_build.sh" || { echo "🔴 构建失败"; exit 1; }; fi   # 11-04：同树一把锁、S2A_CS 只升不降（tools/host_build.sh）
export S2A_RUN_S=$SEC S2A_FRAMES_TSV=$D/frames.tsv
# 表外宏收集（帧率能耗线）：缺省写本局私有目录 <局目录>/macro（不碰共享语料——10-20 画幅线一局写进 run/s2arm/macro/mk8d，gfx 门禁宏表核对全员红）；
# 要补进离线宏表时显式设 S2A_MACRO_DUMP=<目录>，再按 graphics/tools/macrogen/regen.sh 把语料拷进仓库
export S2A_MACRO_DUMP=${S2A_MACRO_DUMP:-$D/macro}; mkdir -p "$S2A_MACRO_DUMP"
# 文档 / 自动玩家输出 / Ryujinx 数据 / 渲染器着色器缓存缺省一律局目录私有（10-20 共性根因 B 类：缺省落到整机共用的 ~/Documents，几局并行互踩系统存档、S2A_Init 失败）；
#   暖局要复用缓存就由调用方显式给同一个目录
export S2A_DOCS=${S2A_DOCS:-$D} S2A_AUTOPLAY_OUT=${S2A_AUTOPLAY_OUT:-$D}
export S2A_RYU_DATA=${S2A_RYU_DATA:-$D/ryu} NXGAL_SHADER_CACHE_DIR=${NXGAL_SHADER_CACHE_DIR:-$D/gal}; mkdir -p "$S2A_RYU_DATA" "$NXGAL_SHADER_CACHE_DIR"
# 游戏数据（服务接入线 S2A_Init 登记游戏用：exefs/main.npdm、romfs/、ctl/control.nacp）：没给就用产物根本身
[ -z "${S2A_GAME_DATA:-}" ] && [ -d "$IN/romfs" ] && export S2A_GAME_DATA=$IN
# 存档：没显式给 S2A_SAVE_DIR 就用和真机局同一份正式局存档的副本（tools/mac_save.sh，10-24 维护者）
source "$ROOT/tools/mac_save.sh"; mac_save_prep "$G" "$IN" "$D" > "$D/save.txt" || exit 1
mac_slot_acquire() { :; }; mac_slot_release() { :; }; [ -z "${S2A_PRIVATE_TOOLS:-}" ] || source "$S2A_PRIVATE_TOOLS/mac_slot_frozen.sh" || exit 1; [ -n "${S2A_MAC_SLOT_HELD:-}" ] || { mac_slot_acquire "$G $D" || exit 1; export S2A_MAC_SLOT_HELD=1; }; trap mac_slot_release EXIT   # Mac 局全机并发上限（维护方设施：设了 S2A_PRIVATE_TOOLS 才排队，没设单机直接起）
"$ROOT/build/s2arm-host" "$MODS" > "$D/host.log" 2>&1 & PID=$!
LIM=$(( ${S2A_MEM_MB:-16384} * 1024 )); T0=$SECONDS; why=
# 测试成本账本（维护方设施 维护方工具，没设不记）：每局收局记一行，线 / 为什么来自调用方的 COST_LINE / COST_WHY；mac_health.sh 自己记，设 S2A_COST_BY_CALLER=1 免重记
cost_log() { :; }; [ -z "${S2A_PRIVATE_TOOLS:-}" ] || source "$S2A_PRIVATE_TOOLS/cost_log.sh"; trap 'mac_slot_release; [ -n "${S2A_COST_BY_CALLER:-}" ] || cost_log mac "$G" $((SECONDS - T0)) "rc=${rc:-?}${why:+ $why}" "$D"' EXIT   # 退出时放 Mac 局槽
# 墙钟上限 = 局秒数 + 30 + 局时顺延上限（宿主 S2A_RUN_EXTEND_MAX：自动玩家等视觉模型的秒数不算局时，到点后按它顺延；11-01 Sniper Elite V2 顺延 80 秒被 450 秒墙钟杀、普查记成「局异常退出」）
WALL=$((SEC + 30 + ${S2A_RUN_EXTEND_MAX:-0}))
while kill -0 $PID 2>/dev/null; do
  sleep 1
  m=$("$PY" -B "$ROOT/tools/phys_footprint.py" $PID --rss 2>/dev/null); fp=${m%% *}; rss=${m##* }
  if [ -z "$m" ]; then rss=$(ps -o rss= -p $PID 2>/dev/null | tr -d ' '); [ -n "$rss" ] && [ "$rss" -gt "$LIM" ] && { why="常驻页集 ${rss} KB 超上限 ${LIM} KB（取不到物理足迹，按常驻页集判）"; kill -9 $PID; break; }
  elif [ "$fp" -gt "$LIM" ]; then why="物理足迹 ${fp} KB 超上限 ${LIM} KB（常驻页集 ${rss} KB）"; kill -9 $PID; break; fi
  [ $((SECONDS - T0)) -gt $WALL ] && { why="超墙钟 $WALL 秒没收局"; kill -9 $PID; break; }
done
wait $PID; rc=$?
# 本局见过的管线并进管线种子来源目录（审计 #1534 P1-54 B4，tools/pso_seed_keep.sh）：宿主写在 $S2A_DOCS/wire/<程序号>/（11-07 起不再写 ~/Documents），
#   出包只读 pso_seed/；崩溃 / 超限的局照拷（见过的就是真用过的）
source "$ROOT/tools/pso_seed_keep.sh" && S2A_PY=$PY pso_seed_keep_mac "$MODS"
[ -n "$why" ] && { echo "【红】$why" >> "$D/host.log"; echo "🔴 ${G}：$why"; exit 1; }
grep -q CRASH "$D/host.log" && { echo "🔴 ${G}：崩溃（见 $D/host.log）"; exit 1; }
echo "$G 收局 rc=${rc}，$(grep -h '未实现系统调用' "$D/host.log" | tail -1 | sed 's/^\[s2a\] //')"
exit $rc
