#!/bin/bash
# 出包·刷新现行产物根：pack/refresh.sh <款>
# 按依赖顺序跑各阶段（改写 ‖ 系统数据 ‖ 宽屏界面布局 ‖ 追加内容 → 能力清单 → RomFS 索引 → 着色器），每段与现行的阶段键相同就跳过（各段自己判，跳过只花算键的几秒），
# 键过期（本树的改写器 / 服务层 / 着色器翻译器 / 布局工具变了）就在新版本产物根里重出并切现行。任一段红 → 退出非 0，现行停在出红前那一版。
# 出包（pack/ipa.sh）与 Mac 局（tools/mac_health.sh）起跑前都先调它：产物根落后于代码树时不许出包、不许起局
# （10-20：26ab181 改了着色器翻译器版本，现行产物根里的旧 Ryujinx 磁盘缓存整批作废、开局同步重编 9125 个，游戏 200 秒一帧不出）。
# 元数据 ctl/control.nacp 要游戏原始包才能抽（pack/stage_nacp.sh <款> <xci / nsp>），这里只核在不在。
# 着色器排最后：它的键含产物根内容哈希，排在会改 romfs 的布局阶段之前会让下次刷新白烘一遍。
set -u
G=${1:?款}; H=$(cd "$(dirname "$0")" && pwd); source "$H/roots.sh"
# 统一工具链（tools/toolchain.env）：各阶段的键含编译器版本（直连库含 iOS Metal 版本），入口不切就按 xcode-select 缺省那套算键、编库——
#   10-25 一键出包外层的 refresh 没切（缺省 Xcode metal 32023.883），ipa.sh 里的 refresh 切了（27.1，32023.921），直连库键不同、整份重出一遍。在这里切，各入口同一套
if [ "${S2A_PACK_PLAT:-ios}" != android ] || [ "$(uname -s)" = Darwin ]; then
  source "$H/../tools/toolchain.sh" || exit 2
fi
# 并行度按本机核数（tools/cores.sh，10-25 jhz「要适配机器的核心数」）；阶段进度写进 S2A_PROGRESS（tools/progress.sh：一键出包每 30 秒打、启动器阶段条读）
source "$H/../tools/cores.sh"; s2a_cores || exit 1; source "$H/../tools/progress.sh"
# 开工判一次盘（tools/disk_low.sh disk_need）：不够当场报红退出，不排队等
source "$H/../tools/disk_low.sh"; disk_need "$G" "${S2A_PACK_NEED_GB:-40}" || exit 1
# 内存 + 核数准入（11-04）不在这里包：下沉到 translator/dsh_batch.py 的 build（谁起的整份出库都过同一本账，只记一次）；这里只把款名交给它当账本键（S2A_MEM_KEY）
CUR=$(root_cur "$G"); [ -n "$CUR" ] || { echo "【红】$G 没有现行产物根（先 pack/seed_root.sh）"; exit 1; }
[ -f "$CUR/ctl/control.nacp" ] || { echo "【红】$G 现行产物根没有 ctl/control.nacp（pack/stage_nacp.sh $G <xci / nsp>）"; exit 1; }
# 改写 / 系统数据 / 界面布局三段产物互不重叠、输入互不依赖：并行跑（各段 root_commit 声明 ROOT_REPLAY，后提交的重放到新现行）；RomFS 索引要等布局改完 romfs，着色器最后
# 同一款同时只一份刷新（10-25 总指挥：巫师3 两棵合入后钩子树各跑一份 refresh，同样的阶段两份一起算）：后到的等前一份刷完再跑——各段按键跳过，等完只花算键的几秒。
#   锁 = <S2A_REFRESH_LOCKS，缺省 ~/.s2arm/run/s2arm/locks>/refresh_<款>.lock（内核文件锁 tools/plock.sh，本进程退出即放；审计 P1-27）；等满 S2A_REFRESH_WAIT_S（缺省 10800）秒报红。
#   子进程（如 ipa.sh 再调本脚本）认 S2A_REFRESH_HELD=<锁名：款，私有根是 款@哈希>，不重复拿
#   锁按「根目录 + 款」（总指挥 10-27 00:4x：塞尔达两份私有包在不同私有根里也共用 refresh_botw，R43 野外档包干等 zhz 那份 1 小时）：
#   共享现行根照旧 refresh_<款>；私有根 refresh_<款>@<私有根真实路径的短哈希>，同款不同私有根可并行，同一私有根仍一份一份来
LK=$G; _root_shared || LK="$G@$(printf '%s' "$(_root_resolve_dir "$S2A_ROOTS")" | shasum | cut -c1-12)"
RL=${S2A_REFRESH_LOCKS:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/locks}/refresh_$LK.lock
if [ "${S2A_REFRESH_HELD:-}" != "$LK" ]; then
  source "$H/../tools/plock.sh"; t0=$SECONDS; said=
  if ! plock_take "$RL" 0; then said=1; echo "$G 已有一份刷新在跑（pid $(plock_holder "$RL")），等它刷完"
    PLOCK_POLL_S=${S2A_REFRESH_POLL_S:-5} plock_take "$RL" "${S2A_REFRESH_WAIT_S:-10800}" || { echo "【红】$G 等前一份刷新 ${S2A_REFRESH_WAIT_S:-10800} 秒没等到（pid $(plock_holder "$RL")）"; exit 1; }; fi
  export S2A_REFRESH_HELD=$LK; [ -n "$said" ] && echo "$G 前一份刷新已完（等了 $((SECONDS - t0)) 秒），接着按键核对"
  CUR=$(root_cur "$G")   # 等的期间前一份可能切了现行
fi
# 退出时删锁只删自己的（并行段的子 shell 被杀时也会跑 EXIT 陷阱：按 BASHPID 核持有者）
# 各阶段输出 / 退出码目录放产物根目录下 .refresh/（10-30 出包线：原先在共享 ${TMPDIR}，跑一两个小时的刷新中途整个目录被删——botw-exp-8404 / 5afe 末尾读不到
#   shaders.rc，报「停在 shaders（rc=9）」、真因丢了）。刷新失败整份留进 .failed/refresh_<款>_<时刻>/（各阶段输出全文），成功才删；只有主进程收尾
L=$(_root_resolve_dir "$S2A_ROOTS")/.refresh/$G.$$; rm -rf "$L"; mkdir -p "$L" || { echo "【红】$G 建不了刷新工作目录 $L"; exit 1; }
case $(dirname "$L") in */.refresh) for d in "$(dirname "$L")/$G".*; do p=${d##*.}   # 被 kill -9 的刷新留下的：只清本款、名字是「款.进程号」且进程已不在的
  case $p in ''|*[!0-9]*) continue;; esac; [ "$d" = "$L" ] || kill -0 "$p" 2> /dev/null || rm -rf "$d"; done;; esac
trap 'rc=$?; [ "$BASHPID" = $$ ] && tsum; if [ "$BASHPID" = $$ ]; then if [ "$rc" = 0 ]; then rm -rf "$L"; else KF=$(dirname "$(dirname "$L")")/.failed/refresh_${G}_$(date +%m%d-%H%M%S); mkdir -p "$(dirname "$KF")" && mv "$L" "$KF" && echo "  $G 刷新各阶段输出留在 $KF"; fi; fi; [ "$(cat "$RL/pid" 2> /dev/null)" = "$BASHPID" ] && rm -rf "$RL"' EXIT
# 分阶段用时（10-26 交付线：子阶段日志在 ${L}、跑完就删，出包成功也只剩进度行，看不出时间花在哪）：每段记自己的墙钟秒数（并行段各记各的），
#   刷新退出时（成功 / 失败都打）一行「⏱ … 分阶段用时」进调用方日志（一键出包 / 启动器出包日志都留着）
TS0=$SECONDS; TM=$L/tm.tsv
tm() { printf '%s\t%s\n' "$1" "$2" >> "$TM"; }
tsum() { [ -s "$TM" ] || return 0
  echo "⏱ $G 刷新分阶段用时（秒，并行段各记各的墙钟）：$(awk -F'\t' '{printf "%s%s %s", (NR > 1 ? " · " : ""), $1, $2}' "$TM")；刷新共 $((SECONDS - TS0)) 秒"; }
# 原件版本核对（pack/srcver.sh，10-25 总指挥：动森共享根停在 3.0.0、本机原件已是 3.0.3，追加内容一直报黄跳过、正式包不带 DLC）：
#   现行程序版本与本机原件不同 → 红、不刷（要按原件重解）；本机没有该款原件（mini / 别的机器）→ 黄、照常刷
bash "$H/srcver.sh" "$G" > "$L/srcver.out" 2>&1; rc=$?; tail -1 "$L/srcver.out"
case $rc in 0|2) ;; *) echo "【红】$G 刷新停在原件版本核对（rc=${rc}），现行 = $(basename "$CUR")"; exit 1;; esac
# 普查精简档（S2A_PACK_LITE=1，一键出包 --lite；10-26 总指挥 / 运维线：普查只答「零配置能不能起来、第一失败点在哪」，通用档出包 280–1267 秒、大头是着色器全量预编）：
#   只跑改写 / 系统数据 / 追加内容 / RomFS 索引，跳过宽屏界面布局、宽屏自动出表、直连配置推导 / 抽取 / 直连库、着色器全量预编（含管线归档、社区数据）；
#   Mac 局着色器首遇现编兜底（runtime/run_mac.sh 只要改写产物 + romfs + control.nacp）。产物根照常可起 Mac 局；不给玩家出包用
# Android keeps its existing make_pack rewrite as the sole module producer.
# Run only shared content preparation and the offline Vulkan direct library
# (#783) here; Metal/Apple module outputs do not belong to the Android package.
# The ordinary Apple route below is unchanged.
if [ "${S2A_PACK_PLAT:-ios}" = android ]; then
  for android_stage in sysdata aoc; do
    ( t=$SECONDS; bash "$H/stage_$android_stage.sh" "$G" > "$L/$android_stage.out" 2>&1; echo $? > "$L/$android_stage.rc"; tm "$android_stage" $((SECONDS - t)) ) &
  done
  wait
  for android_stage in sysdata aoc; do
    tail -1 "$L/$android_stage.out"; rc=$(cat "$L/$android_stage.rc" 2>/dev/null || echo 9)
    [ "$rc" = 0 ] || { sed '$d' "$L/$android_stage.out"; echo "【红】$G 刷新停在 $android_stage 阶段（rc=${rc}），现行 = $(basename "$(root_cur "$G")")"; exit 1; }
  done
  prog_tick 刷新各阶段 2 6
  # 能力清单（F7 #1574：安卓与苹果同口径——make_pack.py 只收 plat android 头的清单，没有它安卓包永远出不来；
  #   安卓没有改写阶段，stage_caps.sh 按安卓改写键 + 宽屏表的安卓行进键）。任一段红照旧退出非 0。
  t=$SECONDS; out=$(bash "$H/stage_caps.sh" "$G" 2>&1); rc=$?; tm caps $((SECONDS - t)); echo "$out" | tail -1
  [ "$rc" = 0 ] || { echo "$out" | sed '$d'; echo "【红】$G 刷新停在 caps 阶段（rc=${rc}），现行 = $(basename "$(root_cur "$G")")"; exit 1; }
  prog_tick 刷新各阶段 3 6
  t=$SECONDS; out=$(bash "$H/stage_romfsidx.sh" "$G" 2>&1); rc=$?; tm romfsidx $((SECONDS - t)); echo "$out" | tail -1
  [ "$rc" = 0 ] || { echo "【红】$G 刷新停在 romfsidx 阶段（rc=${rc}），现行 = $(basename "$(root_cur "$G")")"; exit 1; }
  prog_tick 刷新各阶段 4 6
  export S2A_RESOURCE_KEY_ONCE_FILE="$L/resource-input.key"   # 同苹果路线：抽取与直连库共用这一轮算好的资源输入键
  # 直连库（#783）：NVN 款出离线 Vulkan 库 shaders/direct/b-<链>-vk/（pack/stage_direct.sh，出库目标 android）。
  #   先跑抽取阶段 stage_extract.sh（#783 合入线 11-03 答 1 选 a）：它的键与平台无关，从兄弟平台现行根克隆来的 extract/ 键相同就跳过，没有才抽一次。
  #   这两段跑不跑由 pack/targets/android/target.json 的 direct 阶段声明定（判断走目标描述的阶段条件，不在共用脚本里按平台写分支）：
  #   enabled=false → 跳过抽取与本段、逐段与末行标 skipped、不伪称预编（11-04：安卓运行时未读 LibPack；#1434 接上读库的同一个 PR 把 enabled 改回 true 即恢复，恢复口径写在 target.json 的条件说明里）；
  #   声明读不出 / enabled 不是 false → 照旧跑（默认开）。
  #   开着时的口径（手机端还不读这份库，答 ③）：抽取与直连库这两段任何非 0 都打黄、照常出包（抽取没成就不跑直连库），安卓运行时没有库就现编；
  #   黄项（计数 + 原因）带进末行——一键出包的汇总读的是刷新末行（pack/oneclick/oneclick.sh），不能只留在日志里；输出副本留进 <产物根目录>/.failed/。
  #   接上运行时读库（#1434 第 3 条）后改回：退 3（内容缺口）打黄，其余（工具问题：dotnet / 编译器 / 指纹 / 抽取出错）报红
  CT=${J:-${S2A_DIRECT_J:-$S2A_CPU_BAKE}}; DY=; KF=$(dirname "$(dirname "$L")")/.failed
  ayel() {   # ayel <段> <rc>：记黄项（原因取该段输出末行）、输出副本进 .failed/<款>_android_<段>.out
    DY="安卓直连库没出（$1 rc=$2：$(tail -1 "$L/$1.out" | sed -E 's/^【(红|黄)】//' | cut -c1-200)；运行时现编）"
    if mkdir -p "$KF" && cp "$L/$1.out" "$KF/${G}_android_$1.out"; then echo "🟡 $G ${DY}，接着出包（输出副本 $KF/${G}_android_$1.out）"
    else echo "🟡 $G ${DY}，接着出包（输出副本没留下：写不进 ${KF}）"; fi
  }
  DSKP=$("${S2A_PY:-python3}" - "$H/targets/android/target.json" <<'PYEOF' 2>/dev/null
import json, sys
try:
    doc = json.load(open(sys.argv[1], encoding="utf-8"))
    stage = next(s for s in doc["stages"] if s["id"] == "direct")
    print("skip" if stage.get("enabled") is False else "run")
except Exception:
    print("run")
PYEOF
)
  if [ "$DSKP" = skip ]; then
    tm extract 0; echo "extract skipped（安卓运行时未读 LibPack，#1434 接上后恢复）"
    tm direct 0;  echo "direct skipped（安卓运行时未读 LibPack，#1434 接上后恢复）"
    prog_tick 刷新各阶段 5 6
    DY="离线 Vulkan 直连库 skipped（安卓运行时未读 LibPack，#1434 接上后恢复）"
  else
    t=$SECONDS; bash "$H/stage_extract.sh" "$G" > "$L/extract.out" 2>&1; rc=$?; tm extract $((SECONDS - t)); tail -1 "$L/extract.out"
    if [ "$rc" != 0 ]; then ayel extract "$rc"
    else
      prog_tick 刷新各阶段 5 6
      t=$SECONDS; J=$CT S2A_CPU_BAKE=$CT S2A_MEM_KEY=$G bash "$H/stage_direct.sh" "$G" > "$L/direct.out" 2>&1; rc=$?; tm direct $((SECONDS - t)); tail -1 "$L/direct.out"
      if [ "$rc" != 0 ]; then ayel direct "$rc"
      elif tail -1 "$L/direct.out" | grep -q '^🟡'; then DY=$(tail -1 "$L/direct.out" | sed 's/^🟡 *//' | cut -c1-200); fi
    fi
  fi
  prog_tick 刷新各阶段 6 6
  echo "🟢 $G Android 共享资源已刷新：$(basename "$(root_cur "$G")")${DY:+；🟡 1 项：$DY}"
  exit 0
fi
LITE=${S2A_PACK_LITE:-0}; sk() { [ "$LITE" = 1 ] && [ "$1" = uilayout ]; }   # 精简档跳过宽屏界面布局（阶段清单保持字面写法：pack/contracts 按它核顺序）
# 快路（11-06 出包速度线，jhz：玩家都是冷出包）：直连单轨、非精简档时直连链不等改写那一组，见下面 FAST 段
FAST=0; [ "${S2A_DUAL:-1}" = 1 ] && [ "$LITE" != 1 ] && FAST=1
rm -f "$L"/rewrite.rc "$L"/sysdata.rc "$L"/uilayout.rc "$L"/aoc.rc
for s in rewrite sysdata uilayout aoc; do sk $s && continue; ( t=$SECONDS; bash "$H/stage_$s.sh" "$G" > "$L/$s.out" 2>&1; echo $? > "$L/$s.rc"; tm "$s" $((SECONDS - t)) ) & eval "P_$s=\$!"; done; [ "$FAST" = 1 ] || wait
# 直连库要的 C# 批量进程（translator/dsh_batch.py：按源码摘要编、带文件锁）快路开头就后台编好，不压在抽取之后的关键链上
#   （11-06 出包速度线：玩家引擎副本没有 build/dsh_batch，首次出包原先在直连库里现编，Air 约 25 秒）。编不出不在这里报：直连库那次调用照旧编、照旧报红
[ "$FAST" = 1 ] && { "${S2A_PY:-python3}" "$H/../translator/dsh_batch.py" --xfp > "$L/dsh_prewarm.out" 2>&1 < /dev/null & }
S2A_DUAL=${S2A_DUAL:-1}; RD=0; RN=$([ "$S2A_DUAL" = 1 ] && echo 11 || echo 7); [ "$LITE" = 1 ] && RN=5   # 阶段数：并行四段 + 配置推导 + RomFS 索引 + 抽取 + 通用 ‖ 直连 + 客体代码表；只出通用 6
rt() { RD=$((RD + ${1:-1})); prog_tick 刷新各阶段 "$RD" "$RN"; }
# 依赖重排（11-06 出包速度线）：直连链（配置推导 / 抽取 / 直连库）只读 exefs/main、romfs、追加内容与配置推导结果，不读改写 / 系统数据 / 能力表 / RomFS 索引的产物。
#   关键链：追加内容 ‖ 界面布局 → 配置推导 → 抽取 → 直连库 → 着色器只记键 → 客体代码表 → 管线种子表。
#     界面布局改 romfs、抽取与直连库的键含 romfs 抽样（resource_input_key），所以它必须在抽取开工前落定，否则下次热出包白重抽一遍。
#   旁路（后台，与关键链并行）：改写 ‖ 系统数据 → 能力表 → 宽屏自动出表；RomFS 索引（界面布局之后）。各段照旧提交（声明了 ROOT_REPLAY，并发提交时重放到新现行），
#     旁路的输出与红行在关键链末尾汇合打出，任一段红照旧退 1；直连库开工前旁路已红就当场停（不白编十几分钟）。
#   精简档 / 兼容模式（S2A_DUAL=0）不走这里，照旧串行（下面原代码）。Air 喷射战士3 基线：直连库前的串行关键路径 184 秒（改写 52 + 能力表 11 + 配置推导 23 + RomFS 索引 26 + 抽取 72）
dred() { echo "【红】$G 直连单轨停在 $1：$2；不退成通用包（要通用包请用兼容模式重新出包：S2A_DUAL=0），现行 = $(basename "$(root_cur "$G")")"; exit 1; }
st1() { local out rc t=$SECONDS; out=$(bash "$H/stage_$1.sh" "$G" 2>&1); rc=$?; tm "$1" $((SECONDS - t)); echo "$out" | tail -1
  [ $rc = 0 ] || { echo "【红】$G 刷新停在 $1 阶段（rc=${rc}），现行 = $(basename "$(root_cur "$G")")"; exit 1; }; }
run_profile() {   # 直连配置推导（零配置，#220）：退 3 = 本款不支持 → 直连单轨报红；其余非 0 = 出包内部出错
  local rc t=$SECONDS; bash "$H/stage_direct_profile.sh" "$G" --require-consumer
  rc=$?; tm direct_profile $((SECONDS - t))
  [ "$rc" = 3 ] && dred "直连配置推导" "直连缺口：配置推导不支持本款（direct_profile rc=3）"
  [ "$rc" = 0 ] || { echo "【红】$G 刷新停在直连配置推导（rc=${rc}）：是出包内部出错，现行 = $(basename "$(root_cur "$G")")"; exit 1; }; }
run_extract() {   # 抽着色器（只做一次，见串行路注释）
  local out rc t
  t=$SECONDS; out=$(bash "$H/stage_extract.sh" "$G" 2>&1); rc=$?; tm extract $((SECONDS - t)); echo "$out" | tail -1
  [ $rc = 3 ] && { echo "$out" | sed '$d' | tail -3; dred "抽取阶段" "$(echo "$out" | grep -a '直连库失败：' | tail -1 | sed 's/^.*\(直连库失败：\)/\1/' | cut -c1-260)"; }
  [ $rc = 0 ] || { echo "$out" | sed '$d' | tail -3; echo "【红】$G 刷新停在抽取阶段（rc=${rc}）：抽取是出包内部出错，现行 = $(basename "$(root_cur "$G")")"; exit 1; }
}
direct_tail() {   # 直连库 → 着色器只记键 → 客体代码表 → 管线种子表
  local out rc t
  # 直连库（并行 S2A_CPU_BAKE 路）→ 出成后着色器阶段只记键（S2A_SHADER_LAZY=1：不出通用离线库 / Ryujinx 缓存，秒级）→ 客体代码表
  CT=${J:-${S2A_DIRECT_J:-$S2A_CPU_BAKE}}
  t=$SECONDS; J=$CT S2A_CPU_BAKE=$CT S2A_MEM_KEY=$G bash "$H/stage_direct.sh" "$G" > "$L/direct.out" 2>&1; rc=$?; tm direct $((SECONDS - t)); tail -1 "$L/direct.out"
  if [ "$rc" != 0 ]; then sed '$d' "$L/direct.out" | tail -5
    [ "$rc" = 3 ] && dred "直连库" "直连缺口：$(sed -n 's/.*直连缺口：//p' "$L/direct.out" | tail -1 | cut -c1-260)"
    echo "【红】$G 刷新停在 direct 阶段（rc=${rc}），现行 = $(basename "$(root_cur "$G")")"; exit 1; fi
  root_has_direct "$(root_cur "$G")" || dred "直连库" "直连库阶段退 0 但产物根里没有 shaders/direct/keys.tsv"
  t=$SECONDS; out=$(S2A_SHADER_LAZY=1 bash "$H/stage_shaders.sh" "$G" 2>&1); rc=$?; tm shaders $((SECONDS - t)); echo "$out" | tail -1
  [ $rc = 0 ] || { echo "$out" | sed '$d' | tail -5; echo "【红】$G 刷新停在 shaders 阶段（rc=${rc}），现行 = $(basename "$(root_cur "$G")")"; exit 1; }
  rt 2
  st1 direct_gk; st1 direct_seed; rt   # 管线种子表（审计 #1534 P1-54 B3）：只写 pso_manifest.tsv 的轻阶段，键 = 直连库阶段键 + 跑局知识 seen.tsv
}
chk() {   # chk <阶段>：照原口径打该段末行，非 0 → 红行、退 1（.out 是该段的整段输出）
  local rc; tail -1 "$L/$1.out"; rc=$(cat "$L/$1.rc" 2>/dev/null || echo 9)
  [ "$rc" = 0 ] || { sed '$d' "$L/$1.out"; echo "【红】$G 刷新停在 $1 阶段（rc=${rc}），现行 = $(basename "$(root_cur "$G")")"; exit 1; }; }
SIDE_DONE=
side_join() {   # 汇合旁路（只一次）：打它的输出，红就退 1
  [ -n "$SIDE_DONE" ] && return 0; SIDE_DONE=1; wait "$P_side"; local rc; rc=$(cat "$L/side.rc" 2>/dev/null || echo 9); cat "$L/side.out"
  [ "$rc" = 0 ] || { echo "【红】$G 刷新停在旁路（改写 / 系统数据 / 能力表 / RomFS 索引，rc=${rc}），现行 = $(basename "$(root_cur "$G")")"; exit 1; }; }
if [ "$FAST" = 1 ]; then
  wait "$P_aoc" "$P_uilayout"; chk aoc; chk uilayout; rt 2
  ( ( for s in rewrite sysdata; do while [ ! -s "$L/$s.rc" ]; do sleep 0.2; done; chk $s; done
    st1 caps
    [ "${S2A_WIDEN_PKG:-0}" = 1 ] && bash "$H/../graphics/widen/scan/auto_pkg.sh" start "$G" handheld
    st1 romfsidx
    # 早装信号（11-06 出包与装机重叠）：此刻现行已有改写产物与最终 romfs、还没有着色器库——启动器（pack/jobs/ipa.py installAfter）据此先出早装件
    #   （pack/early_pack.sh：只出程序 + 不含着色器库的早期资源包）、先装 App、先推大头，与直连库编译并行。只写现行版本名（原子改名），不执行任何外部命令
    #   写不出只打黄（不判旁路失败：早装是锦上添花，出完照常整包装）
    if [ -n "${S2A_EARLY_READY:-}" ]; then
      if basename "$(root_cur "$G")" > "$S2A_EARLY_READY.tmp" && mv "$S2A_EARLY_READY.tmp" "$S2A_EARLY_READY"; then :
      else echo "【黄】早装信号写不出（${S2A_EARLY_READY}）：本次不先装，出完照常整包装"; fi
    fi
  ) > "$L/side.out" 2>&1 < /dev/null; echo $? > "$L/side.rc" ) & P_side=$!
  export S2A_RESOURCE_KEY_ONCE_FILE="$L/resource-input.key"
  # 抽取读配置推导的结果（stage_extract.sh 经 direct_profile_stage.py --selected 取配置档键与目录，键里有它）：两段串行，推导在前
  run_profile
  # 运行时 GLSLC 款（游戏自带 glslcCompile、出包期离线编，glslc_offline.py）抽取要读改写后的模块 main.fixups.tsv：这类款抽取等改写落定再开工
  #   （11-07 质量线：新建私有根 gridfix 两次红「里没有改写后的模块（main.fixups.tsv）：先跑改写阶段」——上面依赖重排把直连链与改写并行，
  #   共享根 / 克隆来的根里有上一版改写产物看不出来，全新根第一次出包抽取抢在改写前面）。判据同 stage_extract.sh（--need 读现行根）；别的款照旧并行
  #   要游戏自带解码器的款（Oodle / LZ5，pack/decoder_need.sh：抽取在 Mac 宿主工具模式里跑游戏的解压代码，同样要 main.fixups.tsv）一样等（11-07 DOOM Eternal 新根两次 0 支）
  source "$H/decoder_need.sh"
  if { [ "$("${S2A_PY:-python3}" "$H/../translator/glslc_offline.py" --need "$(root_cur "$G")" 2> /dev/null)" = yes ] || PY=${S2A_PY:-python3} decoder_need "$H/.." "$(root_cur "$G")/romfs"; } && ! sk rewrite; then
    while [ ! -s "$L/rewrite.rc" ]; do sleep 0.2; done
    [ "$(cat "$L/rewrite.rc")" = 0 ] || side_join
  fi
  run_extract
  rt 2
  [ -s "$L/side.rc" ] && side_join   # 旁路已结束：红就在开编直连库之前停
  direct_tail
  side_join; rt 4
  echo "🟢 $G 现行产物根各阶段与本树一致：$(basename "$(root_cur "$G")")"; exit 0
fi
for s in rewrite sysdata uilayout aoc; do sk $s && continue
  tail -1 "$L/$s.out"; rc=$(cat "$L/$s.rc" 2>/dev/null || echo 9)
  [ "$rc" = 0 ] || { sed '$d' "$L/$s.out"; echo "【红】$G 刷新停在 $s 阶段（rc=${rc}），现行 = $(basename "$(root_cur "$G")")"; exit 1; }
done; rt $([ "$LITE" = 1 ] && echo 3 || echo 4)
# 能力清单（10-29 出包线：从改写阶段拆出的轻阶段，读改写产物；精简档也出——Mac 局 / 普查 / 安卓都读产物根里的 s2a_caps.tsv）
t=$SECONDS; out=$(bash "$H/stage_caps.sh" "$G" 2>&1); rc=$?; tm caps $((SECONDS - t)); echo "$out" | tail -1
[ $rc = 0 ] || { echo "$out" | sed '$d'; echo "【红】$G 刷新停在 caps 阶段（rc=${rc}），现行 = $(basename "$(root_cur "$G")")"; exit 1; }; rt
if [ "$LITE" = 1 ]; then
  t=$SECONDS; out=$(bash "$H/stage_romfsidx.sh" "$G" 2>&1); rc=$?; tm romfsidx $((SECONDS - t)); echo "$out" | tail -1
  [ $rc = 0 ] || { echo "【红】$G 刷新停在 romfsidx 阶段（rc=${rc}），现行 = $(basename "$(root_cur "$G")")"; exit 1; }; rt
  echo "🟢 $G 精简档（普查）：改写 / 系统数据 / 追加内容 / RomFS 索引与本树一致，跳过宽屏布局、直连库、着色器全量预编（Mac 局首遇现编兜底）：$(basename "$(root_cur "$G")")"; exit 0
fi
# 宽屏表随同一次出包出（10-25 jhz「一次出包就是完整包」）：改写段已提交宽屏候选（widen_sites.tsv），掌机档（玩家缺省档位）的自动出表此刻起，
#   与下面的着色器 / 直连库并行；ipa.sh 收尾前等它（graphics/widen/scan/auto_pkg.sh wait）。只在出包时（ipa.sh / 一键出包设 S2A_WIDEN_PKG=1），Mac 局刷新不起
[ "${S2A_WIDEN_PKG:-0}" = 1 ] && bash "$H/../graphics/widen/scan/auto_pkg.sh" start "$G" handheld
# 直连优先、零配置（10-25 jhz「咱们不是在做通用直连么」）：缺省每款都出直连库（S2A_DUAL 缺省 1，不看仓库里有没有手写配置档 graphics/nvn/games/<程序号>/game.tsv，
#   手写档只当可选的加速提示）。先零配置推导配置（stage_direct_profile，#220；Vulkan / OpenGL 款不用 NVN 档、直接过），再出直连库。
#   10-30 起直连单轨：内容缺口（推导 / 抽取 / 出库退 3）与基础设施出错一样报红、本次刷新退出 1，写清停在哪一步（见下面 dred）；没有退出 3 / 只出通用这条路了
# 直连单轨（10-30 jhz 拍板：开发阶段只出直连——提速，也让直连还存在的问题暴露出来）：S2A_DUAL 缺省 1 = 只出直连库，不出通用离线库 / 管线归档 / 通用兜底；
#   直连做不成（配置推导不支持本款、抽取只坏直连那份、直连库缺口或退 0 却没出库）一律报红、写清哪一步、退出 1，不退成通用包
#   （10-25 旧坑：直连没出成就静默退回通用，直连的问题一直藏在通用后面）。S2A_DUAL=0 = 兼容模式：显式只出通用（玩家包直连起不来时在 Mac 重新出包用），照旧全量
if [ "$S2A_DUAL" = 1 ]; then run_profile; rt; fi
st1 romfsidx
rt
export S2A_RESOURCE_KEY_ONCE_FILE="$L/resource-input.key"
# 抽着色器只做一次（10-25 jhz）：直连库要的两份抽取在这里出一次进产物根 extract/（pack/stage_extract.sh，键不变就跳过），直连库阶段只读。
#   抽取阶段只有两种正常结果：出成 / 跳过（Vulkan / OpenGL 款没有 NVN 着色器可抽，退 0）；退 3 = 只给直连用的两份抽不出（空洞骑士 Unity 无类型树等）→ 直连单轨报红；
#   其余非 0 是出包内部出错（10-25 一级事故：抽取引用了已删文件、每次失败，当年退成纯通用包、直连库 0 个文件没人发现）
if [ "$S2A_DUAL" = 1 ]; then
  run_extract; rt
  direct_tail
else st1 shaders; rt; fi   # 兼容模式（S2A_DUAL=0）：只出通用，照旧全量
echo "🟢 $G 现行产物根各阶段与本树一致：$(basename "$(root_cur "$G")")"
