#!/bin/bash
# 出包·共享·着色器阶段（J07 #183）：pack/stages/shaders.sh <款> [--ref <Ryujinx 缓存目录>]…
# 与目标无关的部分（本文件）：收集游戏输入与运行时收集表、算键、判断是否已做、在产物根 shaders/ 里提交；
#   产物路径固定 shaders/，不含 ios / android / ohos。真正的烘焙交给目标插件给的后端（S2A_SHADER_PACK，
#   缺省 graphics/tools/shader_pack.sh = 目前的 Metal 后端）：换目标只换后端，共享阶段不写目标名、ABI、宿主工具链。
# 实现搬自 pack/stage_shaders.sh（对外命令行与行为不变，旧入口只剩一层转发 + iOS 缺省参数）。
# 全量静态预编（帧率能耗线的 graphics/tools/shader_pack.sh：抽取 → 分阶段独立翻译 → 离线 metallib + Ryujinx 磁盘缓存），产物放新版本产物根 shaders/：
#   gal.<片号>.metallib + gal.shards + gal.idx、shcache/<程序号>/…、shader_pack.json（红数分项：no_rule / xlate / compile / wall_s）、shader_pack.key
# 缓存键：shader_pack.sh --key <产物根>（游戏输入 + 翻译器 C# 编译闭包 + GAL 翻译代码二进制 + 烘焙脚本 + 工具链版本，见 shader_pack.sh key_of），与现行产物根 .stage_shaders 相同就跳过；
#   键变了也只重编内容变了的程序（抽取 / .air / 管线分片各有内容缓存），结论行报「重编 MSL x / 总数 支、管线 y / 总数 片」。
# 有红（退出非 0）→ 中止新版本、现行不动、报红数；不许静默丢。ipa.sh 把整个 shaders/ 放进资源包（运行时 S2A_GAME_DATA/shaders/）。
set -u
G=${1:?款}; shift; H=$(cd "$(dirname "$0")/.." && pwd); R=$(cd "$H/.." && pwd); source "$H/roots.sh"; source "$H/stage_keyfiles.sh"; stage_deps_on || exit 1; SELF=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")   # 实际读入进键（pack/stage_keyfiles.sh）
SP=${S2A_SHADER_PACK:-$R/graphics/tools/shader_pack.sh}; [ -f "$SP" ] || { echo "【红】没有 ${SP}（帧率能耗线的全量预编工具，或目标插件用 S2A_SHADER_PACK 指定的后端）"; exit 1; }
CUR=$(root_cur "$G"); [ -n "$CUR" ] || { echo "【红】$G 没有现行产物根"; exit 1; }
# 直连就绪款的通用兜底不预编（C.3，10-26 总指挥定范围）：refresh.sh 等直连库实际出成之后才以 S2A_SHADER_LAZY=1 调本阶段——通用只是兜底、几乎用不上，
#   不抽取、不翻译、不编 4.5 万支函数库，也不带 Ryujinx 着色器缓存（带了缓存却没库，开机要整份重翻重编）；兜底真用到时同「无着色器包」：Ryujinx 首遇翻译、渲染器现编（阻塞等编完）。
#   只能走通用的款（直连失败 / 缺口）refresh.sh 不给这个开关，照旧全量预编。新根 shaders/ 里除 direct/ 外的旧通用产物清掉（不沿用上一版的通用库）
# 一包通用（10-30 总指挥）：这条放在算烘焙键之前——什么都不出，键只认本阶段自己（脚本与实际读入），不取 shader_pack.sh --key（那个键含目标机型 / 系统大版本的归档对，
#   目标表里没有的对还直接报红），也不带 -os / -a / -sc 等后缀：换机型 / 系统大版本出包，这一段同键跳过、包键不变
if [ "${S2A_SHADER_LAZY:-0}" = 1 ]; then
  KD=sh; K=$(stage_deps_key "$CUR" shaders "$KD" "$SELF") || exit 1; K="$K-lazy"
  root_stage_done "$CUR" shaders "$K" && { echo "🟢 $G 现行已是着色器 ${K}（兜底不预编），跳过"; exit 0; }
  TAG=$(root_tag "$G" "sh-lazy"); W=$(root_begin "$G" "$TAG") || exit 1
  mkdir -p "$W/shaders"; for e in "$W"/shaders/* "$W"/shaders/.[!.]*; do [ -e "$e" ] && [ "$(basename "$e")" != direct ] && _root_rm "$e"; done
  k=$(stage_deps_save "$W" shaders "$KD" "$SELF") && echo "$k-lazy" > "$W/.stage_shaders" || { root_abort "$G" "$TAG"; exit 1; }
  ROOT_REPLAY='shaders !shaders/direct .stage_shaders .stage_shaders.deps' root_commit "$G" "$TAG" || exit 1
  echo "🟢 $G 直连库已出成：通用兜底不预编（不出函数库 / Ryujinx 缓存，兜底用到时首遇现编）；记键 $(cat "$(root_cur "$G")/.stage_shaders")"; exit 0
fi
K=$(bash "$SP" --key "$CUR" 2>/dev/null | tail -1); [ -n "$K" ] || { echo "【红】取不到着色器缓存键（shader_pack.sh --key）"; exit 1; }
# 改出包内容的开关也进键（取缺省值时键不变，现有包不白烘）：NXGAL_VPULL=0 / S2A_RUNTIME_STATE=0 出 GPU 代价对照包——不进键会被当成「已做过」跳过，对照包和正式包一模一样
[ "${NXGAL_VPULL:-1}" = 1 ] || K="$K-vpull${NXGAL_VPULL}"; [ "${S2A_RUNTIME_STATE:-1}" = 1 ] || K="$K-rs${S2A_RUNTIME_STATE}"
# 实际读入（判组合 / 特化 / 归档用到的 Python 工具与表）折进键；后面加的 -sc / -lazy 后缀照旧在它之上。sh_save：各提交点写阶段键，用本次新清单、同一组后缀
KD=$K; K=$(stage_deps_key "$CUR" shaders "$KD" "$SELF" "$SP") || exit 1; KE=$K
sh_save() { local k; k=$(stage_deps_save "$W" shaders "$KD" "$SELF" "$SP") || return 1; printf '%s%s\n' "$k" "${K#"$KE"}"; }
# 管线归档的目标系统大版本（tools/oneshot.sh 按目标机读来传入；不设时 shader_pack 取本机最新 SDK 大版本）
[ -z "${S2A_PSO_OS:-}" ] || K="$K-os${S2A_PSO_OS// /_}"
# macOS 包的归档按本机系统大版本出（shader_pack.sh）：进键，系统大版本升级后重出归档，不沿用旧系统编的那份
[ "${S2A_PACK_PLAT:-ios}" = ios ] || K="$K-mac$(sw_vers -productVersion | cut -d. -f1)"
# 目标设备 GPU 架构（前端「打 iPhone 包」/ tools/oneshot.sh 按目标机读来传入，pack/jobs/target.py）：换机型 = 换归档和函数体动态库，必须进键；
#   取目标插件给的本平台缺省时键不变：iOS 入口（pack/stage_shaders.sh）给的缺省比较值是 ios / applegpu_g18p，
#   而它没给 S2A_PSO_ARCHS 时会先解析出「包声明机型用到的全部架构」导出——多架构时带 -a<集合> 进键、重烘一次（产物变了）。
#   只有解析不到（回退 applegpu_g18p、不导出）时才与旧键逐字节相同。
#   共享阶段本身不写目标名：两个缺省变量由目标插件给，缺省（没给）时不匹配任何架构 → 照旧进键。
[ -z "${S2A_PSO_ARCHS:-}" ] || [ "${S2A_PACK_PLAT:-}:${S2A_PSO_ARCHS}" = "${S2A_PSO_ARCH_DEFAULT_PLAT:-}:${S2A_PSO_ARCH_DEFAULT_ARCHS:-}" ] || K="$K-a${S2A_PSO_ARCHS// /_}"
# 管线归档的平均片长 S2A_PSO_P（缺省 40，见 shader_pack.sh）、每进程编译线程数 PSO_NTJ（缺省 1，空串 = 编译器自定）改归档字节：取非缺省值才进键（缺省时键不变）；本机并行片数 S2A_PSO_J 只改快慢、不进键
[ "${S2A_PSO_P:-40}" = 40 ] || K="$K-p${S2A_PSO_P}"; [ "${PSO_NTJ-1}" = 1 ] || K="$K-j${PSO_NTJ}"
# 兜底不出管线归档（S2A_SHADER_NO_PSO=1；docs/方案_快速通用模式.md §4「通用模式着色器只为兜底」，10-24 总指挥）：不编 gal_pso.*.bin，函数体动态库 / metallib 照出，
#   运行时本机架构没有归档只记一行、首遇现建（graphics/loop/ShaderPack.cs）。产物形态不同，进键；缺省（不设 / 0）键不变、照出归档
[ "${S2A_SHADER_NO_PSO:-0}" = 0 ] || K="$K-nopso"
# 首局根治 C①（画面·着色器线 10-21）：先收回各局拉回的运行时缓存（graphics/tools/shbake/shcollect.sh：只收含包里没有的客体代码的），
#   收集目录里每份作 --ref-guest 交给烘焙（包里没有的代码按缺省状态翻进包）；各份内容指纹进键：收到新代码 → 键变 → 下次刷新重烘（只重编新增的程序）
#   10-25 总指挥停用（随 main 合入）：扫旧局 + S2A.ShBake guest-new 每次刷新都跑，是本机负载大头之一（通用模式只为兜底）。缺省不收；S2A_SHCOLLECT_RUN=1 手动收一次。
#   已收到的目录照旧作 --ref-guest（键不变，不白烘）
if [ "${S2A_SHCOLLECT_RUN:-0}" = 1 ]; then
  bash "$R/graphics/tools/shbake/shcollect.sh" "$G" 2>&1 | tail -1
  shcollect_rc=${PIPESTATUS[0]}   # tail 只缩短日志，不能把收集失败变成成功。
  [ "$shcollect_rc" = 0 ] || exit "$shcollect_rc"
fi
RG=(); RGK=; for d in "${S2A_SHCOLLECT:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/shcollect}/$G"/*/*/; do [ -f "$d/shared.toc" ] || continue; RG+=(--ref-guest "${d%/}"); RGK="$RGK $(basename "$d")"; done
[ -z "$RGK" ] || K="$K-rg$(echo "$RGK" | shasum -a 256 | cut -c1-10)"
# 参考库（10-22 总指挥：社区缓存只用组合关系，代码来自本款自己的游戏文件；ShaderBake 4c 按规范 Fp 用静态抽出的着色器配出参考库里的程序，
#   配上的图形程序连同社区特化状态写 reflib_states.tsv，shader_pack.sh 交 refpso.py 换成特化管线 v2 行进归档）：
#   S2A_REFLIB_DIRS（空格分隔，相对 S2A_REFLIB_ROOT：环境 → tools/machine.local，都没有就不用社区参考库 / 客体缓存，不再缺省读开发机数据盘）里每个目录有 <程序号大写>.s2rl 就作 --reflib；
#   只有 .s2rl.zst（grokbot 交回的）就解压进内容缓存 ~/.s2arm/run/s2arm/cache/reflib/<内容指纹>.s2rl 再用。各份内容指纹进键（-rl）；S2A_REFLIB=0 出对照包。
#   缺省两份（10-22 总指挥定）：reflib_v3（Ryujinx 社区缓存，带 Ryujinx 特化状态）+ grokbot_s2rl_all_20261022_1503（yuzu 系，带 yuzu 管线键）——动森 212 行特化管线里两份合并逐字段一致 199（tests/t_refpso.py）
TIDR=$(ls "$CUR/shaders/shcache" 2> /dev/null | head -1 | tr 'a-f' 'A-F'); RLK=
# 新款第一次烘焙时现行根还没有 shaders/shcache/：程序号改取解包写的 unpack.tsv，再没有就读 exefs/main.npdm 的 ACI0（同 pack/srcs.sh prog_id）。
#   10-23 用户体验线：奥德赛一键出包第一遍没带社区参考库（取不到程序号），烘完 shcache 出现，出包时再刷新键多出 -rl、整份重烘第二遍（38 分钟白做）
[ -n "$TIDR" ] || TIDR=$(awk -F'\t' '$1 == "title_id" {print toupper($2)}' "$CUR/unpack.tsv" 2> /dev/null)
[ -n "$TIDR" ] || TIDR=$(python3 -c "import sys,struct;d=open(sys.argv[1],'rb').read();i=d.find(b'ACI0');print('%016X'%struct.unpack_from('<Q',d,i+0x10)[0] if i>=0 else '')" "$CUR/exefs/main.npdm" 2> /dev/null)
RLROOT=${S2A_REFLIB_ROOT:-$(bash "$R/tools/machine.sh" get S2A_REFLIB_ROOT 2> /dev/null)}
if [ "${S2A_REFLIB:-1}" != 0 ] && [ -n "$TIDR" ] && [ -n "$RLROOT" ]; then
  RLR=$RLROOT; RLC=${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/cache/reflib
  for d in ${S2A_REFLIB_DIRS:-reflib_v3 grokbot_s2rl_all_20261022_1503}; do
    RLF=$RLR/$d/$TIDR.s2rl
    if [ ! -f "$RLF" ] && [ -f "$RLF.zst" ]; then
      h=$(shasum -a 256 < "$RLF.zst" | cut -c1-16); mkdir -p "$RLC"
      [ -f "$RLC/$h.s2rl" ] || { zstd -q -d -c "$RLF.zst" > "$RLC/$h.s2rl.tmp.$$" && mv "$RLC/$h.s2rl.tmp.$$" "$RLC/$h.s2rl"; } || { rm -f "$RLC/$h.s2rl.tmp.$$"; echo "【红】$G 参考库解压失败：$RLF.zst"; exit 1; }
      RLF=$RLC/$h.s2rl
    fi
    [ -f "$RLF" ] || continue
    RG+=(--reflib "$RLF"); RLK="$RLK $(shasum -a 256 < "$RLF" | cut -c1-10)"
  done
fi
[ -z "$RLK" ] || K="$K-rl$(echo "$RLK" | shasum -a 256 | cut -c1-10)"
# 客体着色器缓存（10-27 jhz「社区资源要认真对待，在能力 / 功能 / 产品上集成好，我们没有的游戏也作能力补充」；王国之泪 yuzu v10 社区缓存）：
#   社区目录 S2A_GUEST_CACHE_DIRS（空格分隔，相对 S2A_REFLIB_ROOT，缺省 totk_yuzu_v10_1027）与用户导入目录 S2A_USER_SHCACHE（缺省启动器数据目录下「着色器缓存」）
#   里的 <程序号大写>/：yuzu 系缓存文件（文件头 yuzucach，vulkan.bin / opengl.bin）→ graphics/tools/shbake/guest_cache.py 转成客体代码包（内容缓存
#   cache/guestbundle/<内容指纹>.s2gb）作 --ref-bundle；Ryujinx 新格式缓存目录（有 shared.toc）作 --ref-guest。缓存里有、本款静态抽取没有的客体代码
#   按缺省状态翻进通用离线库（ShaderBake 4b，同收回的运行时缓存）；直连库按「控制段 + 代码」寻址，这类缓存没有控制段，不进直连。
#   各份内容指纹进键（-gc）；S2A_GUEST_CACHE=0 出对照包。转不出的不中止出包：社区的报【红】（我方数据），用户导入的报【黄】（输入坏了），都写明原因
#   版本门控（10-27 总指挥：王国之泪这份录于 2023-05 的 1.0 / 1.1，原件 1.4.3，多出的程序大概率用不上、白占 +37 MB）：社区目录的 <程序号>/version.tsv 登记录制版本
#   （versions<TAB>空格分隔的版本号），原件 display_version（unpack.tsv）在其中才并入；不在或没登记 → 不并、打「版本不符未并入」。用户导入的默认与其游戏同版本，不门控
if [ "${S2A_GUEST_CACHE:-1}" != 0 ] && [ -n "$TIDR" ]; then
  GCR=$RLROOT; GCC=${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/cache/guestbundle; GCK=
  GCD=(); [ -z "$GCR" ] || for d in ${S2A_GUEST_CACHE_DIRS:-totk_yuzu_v10_1027}; do GCD+=("社区|$GCR/$d/$TIDR"); done
  GCD+=("用户|${S2A_USER_SHCACHE:-$HOME/Library/Application Support/S2Arm/着色器缓存}/$TIDR")
  GVER=$(awk -F'\t' '$1 == "display_version" {print $2}' "$CUR/unpack.tsv" 2> /dev/null)
  for e in "${GCD[@]}"; do
    who=${e%%|*}; dir=${e#*|}; [ -d "$dir" ] || continue
    if [ "$who" = 社区 ]; then
      gv=$(awk -F'\t' '$1 == "versions" {print $2}' "$dir/version.tsv" 2> /dev/null)
      case " $gv " in *" ${GVER:-?} "*) ;; *) echo "🟡 $G 社区客体着色器缓存版本不符未并入：${dir}（录制 ${gv:-未登记}，原件 ${GVER:-未知}）"; continue;; esac
    fi
    [ -f "$dir/shared.toc" ] && { RG+=(--ref-guest "$dir"); GCK="$GCK $(cat "$dir/shared.toc" | shasum -a 256 | cut -c1-10)"; }
    for f in "$dir"/*.bin; do
      [ -f "$f" ] && [ "$(head -c 8 "$f")" = yuzucach ] || continue
      h=$(shasum -a 256 < "$f" | cut -c1-16); mkdir -p "$GCC"
      if [ ! -f "$GCC/$h.s2gb" ] && ! python3 "$R/graphics/tools/shbake/guest_cache.py" bundle "$f" "$GCC/$h.s2gb" --title "$TIDR" > "$GCC/$h.log" 2>&1; then
        echo "$([ "$who" = 社区 ] && echo 【红】 || echo 【黄】)$G ${who}客体着色器缓存转不出，跳过：${f}（$(tail -1 "$GCC/$h.log" | cut -c1-160)）"; continue
      fi
      RG+=(--ref-bundle "$GCC/$h.s2gb"); GCK="$GCK $h"; echo "🟢 $G 并入${who}客体着色器缓存：${f}（$(grep -a -o '程序 [0-9]*（计算 [0-9]*）' "$GCC/$h.log" | head -1)）"
    done
  done
  [ -z "$GCK" ] || K="$K-gc$(echo "$GCK" | shasum -a 256 | cut -c1-10)"
fi
# 特化管线表（画面·着色器线 10-22，动森冷启动「预热成功还慢」：iPhone 上特化与程序不无关）：graphics/tools/shbake/specpipe.py 把本款各局 host.log 的「特化管线」
#   收成「程序 × 组合」表，交 shader_pack.sh → pso_gen.py 按完整描述出完整管线进包归档（第一局特化前先按完整描述取）。表指纹进键（-sp）：表变 = 归档要变，不走快路径
python3 "$R/graphics/tools/shbake/specpipe.py" "$G" 2>&1 | tail -1
crc=${PIPESTATUS[0]}; [ "$crc" = 0 ] || { echo "【红】$G 特化管线表收集失败（specpipe.py 退出 ${crc}），不拿旧表 / 没有表往下出包"; exit "$crc"; }   # tail 只缩短日志（同上面收回那次）
SPF=${S2A_SHCOLLECT:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/shcollect}/$G/spec_pipes.tsv
if [ -s "$SPF" ]; then K="$K-sp$(shasum -a 256 < "$SPF" | cut -c1-10)"; export S2A_SPEC_PIPES=$SPF; else unset S2A_SPEC_PIPES; fi
# 读帧缓冲变体请求表（画面·着色器线 10-22，塞尔达主几何遍每帧约 46 次拆遍：手机程序走 load_binary、变体只能出包预编）：graphics/tools/shbake/fbrvars.py 把本款各局 host.log 的
#   「读帧缓冲变体缺」收成表，交 shader_pack.sh → 烘焙 gal_xc --fbr 改写 + 预编进离线库、写进程序二进制尾段的变体表。表指纹进键（-fv）：表变 = 离线库与归档要变
python3 "$R/graphics/tools/shbake/fbrvars.py" "$G" 2>&1 | tail -1
crc=${PIPESTATUS[0]}; [ "$crc" = 0 ] || { echo "【红】$G 读帧缓冲变体请求表收集失败（fbrvars.py 退出 ${crc}），不拿旧表 / 没有表往下出包"; exit "$crc"; }   # tail 只缩短日志（同上面收回那次）
FVF=${S2A_SHCOLLECT:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/shcollect}/$G/fbr_vars.tsv
if [ -s "$FVF" ]; then K="$K-fv$(shasum -a 256 < "$FVF" | cut -c1-10)"; export S2A_FBR_VARS=$FVF; else unset S2A_FBR_VARS; fi
# 管线首用表（画面·着色器线 10-22，马车8 换场景首帧建管线全是归档命中、散在几十片里）：graphics/tools/shbake/psouse.py 收本款各正式局「管线首用」行，
#   pso_gen.py（S2A_PSO_USE）把表里的管线按首用先后排进最前面几片；表放进包 shaders/pso_use.tsv（运行时程序建成时后台按表预取）。表指纹进键（-pu）：表变 = 分片要变，不走快路径
python3 "$R/graphics/tools/shbake/psouse.py" "$G" 2>&1 | tail -1
crc=${PIPESTATUS[0]}; [ "$crc" = 0 ] || { echo "【红】$G 管线首用表收集失败（psouse.py 退出 ${crc}），不拿旧表 / 没有表往下出包"; exit "$crc"; }   # tail 只缩短日志（同上面收回那次）
PUF=${S2A_SHCOLLECT:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/shcollect}/$G/pso_use.tsv
if [ -s "$PUF" ]; then K="$K-pu$(shasum -a 256 < "$PUF" | cut -c1-10)"; export S2A_PSO_USE=$PUF; else unset S2A_PSO_USE; fi
# 键→客体指纹对照（10-23，shbake/psoremap.py）：每次烘焙并进本次的键；首用表据此重定位到本包（shader_pack.sh 写包里 shaders/pso_use.tsv）。
#   对照只增、只用来翻译收集时已记下的旧键（旧行来自的包烘焙时已并入），不进键
export S2A_PSO_KEYMAP=${S2A_SHCOLLECT:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/shcollect}/$G/keymap.tsv
# 新机器上收集目录 <款>/ 还没建：psoremap 追加写会报「没有这个目录」（10-23 Air 全冷奥德赛撞红）；在这里建，不动烘焙键里的脚本
mkdir -p "$(dirname "$S2A_PSO_KEYMAP")"
# 特化组合表（画面·着色器线 10-22，动森首遇特化慢：混合组合录像没收全）：graphics/tools/shbake/speccombo.py 把全部款各局 host.log 的「特化组合」收成一张全款共用表，
#   放进包 shaders/spec_combos.tsv（运行时载入后在后台补预热）。表指纹进键（-sc）；烘焙键 KB 没变、只有表变时走快路径：克隆现行只换表，不重烘
python3 "$R/graphics/tools/shbake/speccombo.py" 2>&1 | tail -1
crc=${PIPESTATUS[0]}; [ "$crc" = 0 ] || { echo "【红】$G 特化组合表收集失败（speccombo.py 退出 ${crc}），不拿旧表 / 没有表往下出包"; exit "$crc"; }   # tail 只缩短日志（同上面收回那次）
SCF=${S2A_SHCOLLECT:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/shcollect}/_combos/spec_combos.tsv; KB=$K; SCH=
if [ -s "$SCF" ]; then SCH=$(shasum -a 256 < "$SCF" | cut -c1-10); [ -n "$SCH" ] && K="$K-sc$SCH"; fi
root_stage_done "$CUR" shaders "$K" && { echo "🟢 $G 现行已是着色器 ${K:0:12}，跳过"; exit 0; }
# Vulkan 款（main 导入 vk*：哈迪斯、超级马力欧银河 1 / 2）：包里没有 NVIDIA 机器码着色器——着色器是 SPIR-V，Switch 上由随包的 NVIDIA 驱动（subsdk1）运行时编，
#   全量预编抽不到东西（10-24 哈迪斯 1.0.38233：抽取 0 支，后面出库 / 归档全空、「产物复制失败」整包停）。通用模式这类款靠运行时首遇编（哈迪斯 Mac 通用局照样到 MARK）；
#   直连用 SPIR-V 离线库（pack/stage_direct.sh → graphics/tools/direct/direct_lib.sh「Vulkan 款」）。本阶段只记键，不出 shaders/ 下的通用产物
PY=${S2A_PYTHON:-${S2A_PY:-$(bash "$R/tools/machine.sh" get S2A_PY 2> /dev/null)}}; PY=${PY:-$(command -v python3)}
API=$("$PY" "$R/graphics/nvn/tools/gfx_api.py" "$CUR/exefs") || { echo "【红】$G 判图形接口失败（graphics/nvn/tools/gfx_api.py）：${API#*	}"; exit 1; }   # 出包分流的唯一判法
# OpenGL 款（数码宝贝物语：GLSL 源码由随包的 NVIDIA GL 驱动 subsdk0 运行时编）同理：包里没有机器码着色器，直连用 GLSL 离线库（direct_lib.sh「OpenGL 款」）
if [ "${API%%	*}" = vulkan ] || [ "${API%%	*}" = gl ]; then
  TAG=$(root_tag "$G" "sh-${K:0:10}"); W=$(root_begin "$G" "$TAG") || exit 1
  sh_save > "$W/.stage_shaders"; ROOT_REPLAY='.stage_shaders .stage_shaders.deps' root_commit "$G" "$TAG" || exit 1
  echo "🟢 $G 是 ${API%%	*} 款，包里没有 NVIDIA 机器码着色器：不出通用离线库，通用模式运行时首遇编、直连用离线翻好的库；记键 ${K:0:12}"; exit 0
fi
CK=$(cat "$CUR/.stage_shaders" 2> /dev/null)
# 现行是「兜底不预编」的根（键尾 -lazy，没有离线库）时不走这条：剥掉 -sc 后会和烘焙键相等，只换表就提交成没有通用库的全量根
if [ -n "$SCH" ] && [ -n "$CK" ] && [[ "$CK" != *-lazy ]] && { [ "$CK" = "$KB" ] || [ "${CK%-sc*}" = "$KB" ]; }; then
  TAG=$(root_tag "$G" "sh-${KB:0:10}-sc$SCH"); W=$(root_begin "$G" "$TAG") || exit 1
  cp "$SCF" "$W/shaders/spec_combos.tsv" && sh_save > "$W/.stage_shaders" && ROOT_REPLAY='shaders/spec_combos.tsv .stage_shaders .stage_shaders.deps' root_commit "$G" "$TAG" || { root_abort "$G" "$TAG"; echo "【红】$G 换特化组合表失败"; exit 1; }
  echo "🟢 $G 着色器只换特化组合表（$(grep -vc '^#' "$SCF") 条；烘焙键 ${KB:0:12} 没变，不重烘）"; exit 0
fi
# 开发 / 诊断刷新复用现行着色器产物、不重烘（10-24 jhz「开发测试速度极慢……不需要的测试、门禁、流程一律砍掉」：烘焙只有 1 个槽，
#   动森那次 1869 秒里烘焙本身 380 秒、其余全在排队；九款一起重烘排一个多小时，挡住 Mac 局与诊断）。10-25 起出包也复用（jhz 停掉通用侧占资源的活：通用着色器只为兜底）；S2A_SHADERS_REUSE=0 才按键全量重烘。
#   前提：现行包与本树翻译口径一致——离线索引口径（gal.idx 头 = gal_abi.h NXGAL_XC_VERSION）与 Ryujinx 缓存翻译器版本（shcache/*/shared.toc = CodeGenVersion）。
#   不一致时运行时整份拒用离线库（gal_prog.m「离线索引魔数 / 版本 / 口径不符」）、开局全量现编，只能重烘；一致时本树改了翻译的那部分着色器走运行时首遇安全网现编
if [ "${S2A_SHADERS_REUSE:-1}" = 1 ] && [ -s "$CUR/shaders/gal.idx" ]; then
  RW=$(python3 - "$R" "$CUR/shaders" <<'PY'
import glob, os, re, struct, sys
r, sh = sys.argv[1:3]; bad = []
m, v, xv = struct.unpack_from('<3I', open(os.path.join(sh, 'gal.idx'), 'rb').read(12))
want = int(re.search(r'#define NXGAL_XC_VERSION (\d+)u', open(os.path.join(r, 'graphics/metal/gal_abi.h')).read()).group(1))
if m != 0x494c4147 or v != 1: bad.append(f'离线索引头不认得（魔数 {m:#x} 版本 {v}）')
elif xv != want: bad.append(f'离线索引口径 {xv} ≠ 本树 {want}')
cg = re.search(r'const uint CodeGenVersion = ([0-9 +]+);', open(os.path.join(r, 'compat/tree/src/Ryujinx.Graphics.Gpu/Shader/DiskCache/DiskCacheHostStorage.cs')).read())
cgv = sum(int(x) for x in cg.group(1).split('+'))
tocs = glob.glob(os.path.join(sh, 'shcache', '*', 'shared.toc'))
if not tocs: bad.append('没有 Ryujinx 缓存（shcache/*/shared.toc）')
for t in tocs:
    have = struct.unpack_from('<I', open(t, 'rb').read(12), 8)[0]
    if have != cgv: bad.append(f'Ryujinx 缓存翻译器版本 {have} ≠ 本树 {cgv}'); break
print('；'.join(bad))
PY
) || RW="口径读不出"
  if [ -z "$RW" ]; then echo "🟡 $G 着色器复用现行产物（键 ${CK:0:12} → ${K:0:12}，翻译口径与本树相同；本树改了翻译的着色器走首遇现编；出包才重烘）"; exit 0; fi
  echo "$G 着色器口径与本树不同（${RW}），要重烘"
fi
# 10-21 起的「重烘暂停」（产物根 .pause_shaders 挡重烘）10-25 总指挥定永久撤掉：完整包必须带通用兜底着色器，合入后九款一起重烘已由 cmdr/autofreeze 根治；
#   留着它，main 升通用离线索引口径（19 → 20）后动森正式包红在「重烘暂停中」、现行没切。标记文件不再有任何作用
TAG=$(root_tag "$G" "sh-${K:0:10}"); W=$(root_begin "$G" "$TAG") || exit 1
_root_rm "$W/shaders"; t0=$SECONDS
# 小内存机器按款降并行（10-23 45 分钟采样九款重烘的进程树 RSS 峰值：巫师3 34.3 GB、暗黑3 29.5 GB，其余 6–10 GB；10-24 #253 24 GB Mac mini）：
#   实测 ≤10 GB 的款按 12 GB，其余（含没量过的新款）按 36 GB；峰值随并行路数 J 涨（巫师3 34.3 GB 是 J=9，每路约 4 GB）。
#   超过本机物理内存一半 → J 按每路 = 峰值 ÷ J 降到放得下（至少 1）。调用方给了 S2A_MEM_BAKE_GB 不动
case $G in acnh|botw|mk8d|d2r|mhrise|silksong|octopath2) BAKE_GB=12;; *) BAKE_GB=36;; esac
bake_fit() {   # bake_fit <按款峰值 GB> <J> <物理内存 GB> → 「J 峰值GB」
  local gb=$1 j=$2 cap=$(( $3 / 2 )) per; per=$(( (gb + j - 1) / j ))
  if [ "$gb" -gt "$cap" ]; then j=$(( cap / per )); [ "$j" -ge 1 ] || j=1; gb=$(( j * per )); fi
  echo "$j $gb"; }
if [ -z "${S2A_MEM_BAKE_GB:-}" ]; then
  read -r _bj _bg <<< "$(bake_fit "$BAKE_GB" "${J:-${S2A_CPU_BAKE:-9}}" "$(( $(sysctl -n hw.memsize) / 1073741824 ))")"
  [ "$_bg" != "$BAKE_GB" ] && { echo "$G 重烘：本机内存 $(( $(sysctl -n hw.memsize) / 1073741824 )) GB，按款峰值 ${BAKE_GB} GB 放不下 → 并行 ${_bj} 路"; export J=$_bj; }
fi
# gal_offline 按内存放片（画面·着色器线 pso-fc）：预算固定 16 GB（大款的 34 GB 峰值不在 gal_offline 这一段）
export GAL_LINK_MEM_GB=${GAL_LINK_MEM_GB:-16}
# 并行度：J（翻译 / 编库并行）= S2A_CPU_BAKE（tools/cores.sh 按本机核数与内存定，没设按 9）；本机管线分片并行 S2A_PSO_J 缺省 = J：
#   每个 applegpu-nt 单线程（PSO_NTJ=1，shader_pack.sh 缺省），J 路正好吃满 J 核；其余分片由 pso_dist 的工作窃取交给 mini（同样单线程、道数 = 远端核数）。调用方给了 J / S2A_PSO_J 就用调用方的
#   （10-21 测试机2 暗黑3 冷启动 A/B/C：缺省线程 + 4 路 现建合计 1546 ms、归档 229 MB；单线程 + 12 路 274 ms、127 MB；片长 40 + 单线程 1164 ms、154 MB → 定单线程 + P=300）
export J=${J:-${S2A_CPU_BAKE:-9}}; export S2A_PSO_J=${S2A_PSO_J:-$J}
# 现行包的 shaders/（真实路径：烘的时候现行换了版本也指着烘前那份）交 shader_pack.sh 比产出指纹
SPREV=$(cd -P "$CUR/shaders" 2> /dev/null && pwd)
# 上限按进度判（10-23 总指挥：奥德赛在 Air 上首次出包停在固定 40 分钟上限，玩家那边直接失败）：$W/shaders 下持续有新文件就一直跑，
#   连续 S2A_STAGE_STALL_S（缺省 600）秒没有新文件才判卡死（超时前抓现场写 shader_pack.snap），S2A_STAGE_TIMEOUT 只作总上限（缺省 6 小时）
S2A_SHADERS_PREV=$SPREV S2A_SNAP_STALL="${S2A_STAGE_STALL_S:-600}:$W/shaders" bash "$R/graphics/tools/timeout_snap.sh" "${S2A_STAGE_TIMEOUT:-21600}" "$W/shaders/work/shader_pack.snap" bash "$SP" "$W" "$W/shaders" "$@" ${RG[@]+"${RG[@]}"} > "$W/shader_pack.log" 2>&1; rc=$?
# 产出与现行逐字节相同（shader_pack.sh 退出 3，②½ 产出指纹，10-24 总指挥「输出不变就不算变」）：着色器沿用现行（含 shader_pack.key——运行时按它认包，
#   不变就不换手机上的缓存），只记新键；照常走提交（重放 shaders 与键戳，烘的几分钟里别的树提交了同一款也对）
if [ $rc = 3 ]; then
  _root_rm "$W/shaders"; _root_cp -R "$SPREV" "$W/shaders" && { [ -z "$SCH" ] || cp "$SCF" "$W/shaders/spec_combos.tsv"; } && sh_save > "$W/.stage_shaders" && ROOT_REPLAY='shaders !shaders/direct .stage_shaders .stage_shaders.deps' root_commit "$G" "$TAG" \
    || { root_abort "$G" "$TAG"; echo "【红】$G 沿用现行着色器失败"; exit 1; }
  echo "🟢 $G 着色器产出与现行相同（键 ${CK:0:12} → ${K:0:12}，$((SECONDS - t0)) 秒；$(grep -o '产出指纹 [0-9a-f]*' "$W/shader_pack.log" | head -1)），沿用现行、不重编"; exit 0
fi
# 抽到 0 支（shader_pack.sh 退出 4，10-27 最终幻想 共鸣：着色器全在 Oodle 压缩的 pak 条目里）：同 Vulkan / OpenGL 款只记键、不出通用离线库，
#   通用模式运行时首遇编，出包照常往下走（直连库照常另判）；原先整包停在「产物复制失败」，直连库也没出。
#   原因读 shader_pack 写的 work/zero_unsupported.txt（不从日志抠中文原文）：有「不支持」项 = 抽取器认得出容器却解不了，是我方缺口 → 【红】
#   （同 refresh.sh「直连库失败…本包只有通用模式」：红行响亮报出但不中止，出包结论看退出码）；空 = 包里真没有可认的着色器容器 → 【黄】；文件缺 → 按缺口报红
if [ $rc = 4 ]; then
  if [ -f "$W/shaders/work/zero_unsupported.txt" ]; then why=$(head -1 "$W/shaders/work/zero_unsupported.txt"); else why='抽取原因文件缺失'; fi
  mkdir -p "$W/shaders"; for e in "$W"/shaders/* "$W"/shaders/.[!.]*; do [ -e "$e" ] && [ "$(basename "$e")" != direct ] && _root_rm "$e"; done
  sh_save > "$W/.stage_shaders"; ROOT_REPLAY='shaders !shaders/direct .stage_shaders .stage_shaders.deps' root_commit "$G" "$TAG" || exit 1
  if [ -n "$why" ]; then echo "【红】$G 着色器抽取缺口：${why}；抽取 0 支，不出通用离线库，本包通用模式运行时首遇编；记键 ${K:0:12}"
  else echo "【黄】$G 着色器抽取 0 支（包里没有可认的着色器容器）：不出通用离线库，通用模式运行时首遇编；记键 ${K:0:12}"; fi
  exit 0
fi
[ $rc != 124 ] || echo "【红】$G 着色器预编连续 ${S2A_STAGE_STALL_S:-600} 秒没有新产出（或超总上限 ${S2A_STAGE_TIMEOUT:-21600} 秒），判卡死；现场（失败时存档）$S2A_ROOTS/.failed/${G}_shaders/shader_pack.snap"
# 红数分项在 shader_pack.json 的 red{} 里（旧版在顶层）：全部列出，不挑名字（10-20 只读顶层三项，mk8d no_rule 1 被打成「no_rule 0」）
red=$(python3 -c "import json,sys;d=json.load(open(sys.argv[1]));r=d.get('red') or {k:d.get(k,0) for k in ('no_rule','xlate','compile')};b=d.get('rebuilt') or {};print('，'.join(f'{k} {v}' for k,v in r.items()), f'，重编 MSL {b.get(\"msl\",\"?\")} / {b.get(\"msl_total\",\"?\")} 支、管线 {b.get(\"pso_chunks\",\"?\")} / {b.get(\"pso_chunks_total\",\"?\")} 片，墙钟 {d.get(\"wall_s\",\"?\")} 秒')" "$W/shaders/shader_pack.json" 2>/dev/null)
# 有红时：产物齐全（离线库 + 索引 + 本游戏 Ryujinx 缓存都在、shader_pack.json 有红数）→ 照样提交成「部分包」，红数写 shaders/red.txt、打【红】行、出包结论带上；
#   缺产物（工具中途失败）才中止。10-20：六款（mk8d no_rule 1、mhrise 108…）整包作废后现行里没有 shaders/，Mac 局与 iPhone 包全量现编（几千个），
#   而部分包只漏红的那几个——它们在局里由「必须为 0」闸门（tools/zero_gate.py）逐个点名报红，不静默
PARTIAL=0
shaders_save_failure() {
  F=$S2A_ROOTS/.failed/${G}_shaders
  mkdir -p "$F" && cp "$W/shader_pack.log" "$F/shader_pack.log" || return 1
  # 明细（bake.json / programs.tsv）随版本丢弃前留副本；工具早退时目录可能还不存在。
  [ ! -d "$W/shaders" ] || find "$W/shaders" -maxdepth 3 -type f \( -name bake.json -o -name programs.tsv -o -name shader_pack.json \) -exec sh -c 'dest=$1; shift; for f do cp "$f" "$dest/" || exit 1; done' sh "$F" {} + || return 1
  # 各步日志与超时现场（work/*.log、offline.snap*：10-23 用户体验线 Air 编奥德赛超时，work 随版本丢弃、查不到卡在哪）
  [ ! -d "$W/shaders/work" ] || find "$W/shaders/work" -maxdepth 1 -type f \( -name '*.log' -o -name '*.snap' -o -name '*.snap.digest' \) -exec sh -c 'dest=$1; shift; for f do cp "$f" "$dest/" || exit 1; done' sh "$F" {} + || return 1
}
shaders_keep_failure() {
  shaders_save_failure || { echo "【红】$G 保存着色器诊断失败：保留现场 ${W}，不提交、不清理"; exit 1; }
}
if [ $rc != 0 ]; then shaders_keep_failure
  if [ -s "$W/shaders/gal.shards" ] && [ -s "$W/shaders/gal.idx" ] && [ -n "$(ls "$W/shaders/shcache" 2>/dev/null)" ] && [ -n "$red" ]; then
    PARTIAL=1; echo "$red" > "$W/shaders/red.txt"; echo "【红】$G 着色器全量预编有红（rc=${rc}；${red}；明细副本 ${F}/）：提交为部分包，红的程序首遇现编并在局里点名"
  else echo "【红】$G 着色器全量预编有红且产物不全（rc=${rc}；${red:-没有 shader_pack.json}；日志与明细副本 $F/）"; root_abort "$G" "$TAG"; exit 1; fi
fi
[ -s "$W/shaders/gal.shards" ] && [ -s "$W/shaders/gal.idx" ] || { shaders_keep_failure; echo "【红】$G 预编退出 0 但没有 gal.shards / gal.idx；日志副本 $F/"; root_abort "$G" "$TAG"; exit 1; }
# 管线归档硬判据（10-21 总指挥）：有分片而归档 0 KB → 判红、不提交本版本（现行保持原样、也就不会被登记）；判据 root_pso0 见 roots.sh
[ "${S2A_SHADER_NO_PSO:-0}" = 0 ] && P0=$(root_pso0 "$W") && { shaders_keep_failure; echo "【红】$G 管线归档 0 KB（${P0} 片全部失败；${red:-}）：不提交、不登记，现行保持 $(basename "$(cd -P "$(root_cur "$G")" 2> /dev/null && pwd)")；日志副本 $F/"; root_abort "$G" "$TAG"; exit 1; }
[ -z "$SCH" ] || cp "$SCF" "$W/shaders/spec_combos.tsv" || { shaders_keep_failure; echo "【红】$G 放特化组合表失败；日志副本 $F/"; root_abort "$G" "$TAG"; exit 1; }
# Ryujinx 缓存硬判据（10-26 总指挥：星露谷 0100E65002BB8000 的根 shcache/<程序号>/ 是空目录、没有 shared.toc，阶段照报全量预编成功，
#   真机开局才打「着色器包里没有本游戏的 Ryujinx 缓存」）：shcache 下有某款的目录却没有 shared.toc → 判红、不提交（lazy 模式整个不出 shcache 的不受影响）
for d in "$W"/shaders/shcache/*/; do [ -d "$d" ] || continue; [ -s "$d/shared.toc" ] || { shaders_keep_failure; echo "【红】$G 着色器预编退出 0 但 Ryujinx 缓存不全：$(basename "$d")/ 没有 shared.toc（$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("程序 %s/%s 写出、SPIR-V %s 份" % (d.get("programs_written"), d.get("programs_total"), d.get("spv")))' "$W/shaders/shader_pack.json" 2>/dev/null)）；日志副本 $F/"; root_abort "$G" "$TAG"; exit 1; }; done
_root_rm "$W/shaders/work"   # 中间产物（SPIR-V 等，动森约 0.5 GB）不留在产物根
# 包里 shaders/pso_use.tsv 由 shader_pack.sh 写（重定位到本包后的表）
sh_save > "$W/.stage_shaders"; ROOT_REPLAY='shaders !shaders/direct shader_pack.log .stage_shaders .stage_shaders.deps' root_commit "$G" "$TAG" || exit 1   # 烘几分钟里别的树提交了同一款（10-20 合入后自动正式局五轮全红）：只换本阶段产物重放到新现行；新现行的 romfs 若也变了，下次刷新按键不符自会重烘
echo "$([ $PARTIAL = 1 ] && echo "🟡 $G 着色器部分包" || echo "🟢 $G 着色器全量预编")（$((SECONDS - t0)) 秒；${red}；metallib $(python3 -c 'import json,sys; print("%.0fM" % (json.load(open(sys.argv[1]))["metallib_kb"] / 1024))' "$(root_cur "$G")/shaders/shader_pack.json") / $(wc -l < "$(root_cur "$G")/shaders/gal.shards" | tr -d ' ') 片），现行 → $(basename "$(root_cur "$G")")"
