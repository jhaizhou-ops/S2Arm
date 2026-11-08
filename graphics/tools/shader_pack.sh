#!/bin/bash
# 着色器全量预编进包（不启动游戏）：bash graphics/tools/shader_pack.sh <产物根> <输出目录> [--ref <Ryujinx 缓存目录（含 shared.toc）>]… [--ref-guest <收回的运行时缓存目录>]… [--reflib <参考库 .s2rl>]…
#                                    bash graphics/tools/shader_pack.sh --key <产物根>     只打印缓存键
#                                    bash graphics/tools/shader_pack.sh --tool-keys        只打印 CS XC（标准错误打命中记忆 / 现算）
# ① shbake/nxsh_extract.py：扫 <产物根>/romfs 与 exefs/main，抽出全部着色器（rows.tsv + src/）
# ② S2A.ShBake bake：调 Ryujinx 原翻译器出每个程序的 SPIR-V；当场跑 gal_xc（iOS 口径）出离线索引，按索引记录拼宿主程序二进制，
#    写 Ryujinx 磁盘缓存 shcache/<程序号>/（guest + shared + vulkan_nxgal_bin：手机首启不重翻）
# ③ gal_offline.py：MSL → .air（内容寻址缓存）→ 分片 gal.<片号>.metallib（每片 ≤64 MB）+ gal.shards
# ④ shbake/pso_gen.py + applegpu-nt：每个程序一个基础管线（片元输出留空、顶点自取，见 graphics/metal/gal_vpull.m）离线编成 GPU 二进制归档 gal_pso.<架构>.<ios|macos><系统大版本>.<分片>.bin（运行时按描述命中、首遇只特化）
# 产物（<输出目录>/，整个原样进包 Documents/资源包/shaders/）：gal.<片号>.metallib、gal.shards、gal.idx、gal_pso.<架构>.<平台><系统大版本>.<分片>.bin、shcache/<程序号小写>/、shader_pack.json、shader_pack.key
# 中间产物留 <输出目录>/work/（spv/、lib/msl/、抽出集、各步日志），不进包。
# 退出 0 = 无红；1 = 有红（分项见 shader_pack.json red）；2 = 参数 / 环境错；3 = 产出与 S2A_SHADERS_PREV（现行包的 shaders/）逐字节相同、没出产物（见 ②½）。墙钟上限：抽取 900 秒、翻译与编译按进度（连续 600 秒无新产出判挂死，总上限 6 小时）。
# 读帧缓冲（10-22）：烘焙按 S2A_FBR_VARS（变体请求表，pack/stage_shaders.sh 给）跑 gal_xc --fbr，work/fbr.tsv 的证明进程序二进制尾段、变体进离线库，变体基础管线由 pso_gen.py 第 9 个参数出。
# 环境：J = 并行数（缺省 = 核数）；S2A_PACK_PLAT = ios（缺省）| macos（Mac 开发局用的整包：函数库与归档按 macOS / 本机架构）；
#       出哪些（GPU 架构, 系统大版本）对：pack/jobs/archs.py pairs <平台> pso（目标表 pack/pso_targets.tsv + 按用途推导：显式 S2A_PSO_ARCHS × S2A_PSO_OS / S2A_MAC_OS >
#                       S2A_PSO_ARCHS_ALL=1 全集 > S2A_PACK_PURPOSE=user 目标设备 > 缺省跑局机清单 pack/our_devices.tsv）；Metal 3 档自动出老格式；
#       S2A_PSO_M3 = 1 出 Metal 3 老格式归档（.mtlp-json → metal-tt，缺省关）：只在本机编（mini 远端服务只认 .mtl4-json），
#                   归档最低系统版本按本批系统大版本给 <M>.0，必须与运行时系统一致（10-23 实测 27.0 命中、26.0 / 15.0 不命中）
set -u
R=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
source "$R/tools/toolchain.sh" || exit 2   # 统一工具链（tools/toolchain.env，10-22 jhz 全切 27.1）：函数库与管线归档都用这一套
PY=${S2A_PYTHON:-$(bash "$R/tools/machine.sh" get S2A_PY 2> /dev/null)}; [ -n "$PY" ] && [ -x "$PY" ] || PY=python3   # 抽取要 lz4（开发机钉版 venv 在 tools/machine.local 的 S2A_PY 声明）；Yaz0/SARC 用仓库里的 nxfmt；启动器显式使用应用内置 Python
t(){ echo "[$(date +%T)] $*"; }
# 超时包装（#591）：timeout 是仓库的 perl 版 tools/bin/timeout（tools/toolchain.sh 放到 PATH 最前；.app 的 Runtime/bin/timeout 是它的拷贝），不是 coreutils。取不到 timeout / gtimeout 就直接跑、只提示一次，
#   不判失败——原来 `timeout 600 …` 在这类机器上 `command not found` 返回 127，被下游当成「这一步失败」，要么报红要么静默退化
#   （nvn_uses 那段 `|| NU='{}'` 会悄悄按「照旧两份变体」出包）。${TIMEOUT_BIN:+$TIMEOUT_BIN <秒> } 故意不加引号：空时展开成空。
#   只用 command -v 声明随包命令（timeout 在 launchers/macos/bundle_runtime.py 的 TOOLS 里）；gtimeout 是 Homebrew coreutils
#   的带前缀名，本机可选，用 type -P 探（tests/userenv_test.sh ① 只认随包命令，不把 gtimeout 写进 command -v 声明）。
TIMEOUT_BIN=$(command -v timeout || true)
[ -n "$TIMEOUT_BIN" ] || TIMEOUT_BIN=$(type -P gtimeout || true)
[ -n "$TIMEOUT_BIN" ] || t "本机没有 timeout（coreutils 的 timeout / gtimeout），跳过超时保护，抽取与各读取器照跑"

input_fp() {   # 游戏输入指纹：romfs / exefs / aoc（追加内容，10-25 总指挥：通用兜底也覆盖 DLC 里的着色器）文件清单 + 大小、exefs/main 内容
  (set -o pipefail
    cd "$1" || exit 1
    # GNU 优先；失败的 stdout（GNU stat -f 会输出文件系统信息）不能混入指纹。
    # romfs 的文件清单经 graphics/nvn/tools/romfs_list.py files0（仓库里唯一的 RomFS 遍历；同 find romfs -type f -print0，读不开的目录同样报错退非 0）
    local files main
    files=$({ "$PY" "$R/graphics/nvn/tools/romfs_list.py" files0 romfs && find exefs $([ -d aoc ] && echo aoc) -type f -print0; } | sort -z | xargs -0 stat -c '%n %s' 2>/dev/null) ||
      files=$({ "$PY" "$R/graphics/nvn/tools/romfs_list.py" files0 romfs && find exefs $([ -d aoc ] && echo aoc) -type f -print0; } | sort -z | xargs -0 stat -f '%N %z') || {
        echo "🔴 游戏输入指纹读不出（stat）" >&2; exit 1;
      }
    main=$(shasum -a 256 < exefs/main) || exit 1
    printf '%s\n' "$files" | shasum -a 256 || exit 1
    printf '%s\n' "$main"
  )
}
# 本款会不会按原画框外推（宽屏层 SpirvExtrap）：产物根里整套放宽表 widen_full.<档位>.tsv 有一行「1」= 整套放宽款，注入外推；
#   没有（游戏自己出宽 / 16:9 款，外推永远不开）不注入——10-23 塞尔达：片元里哪怕不执行的导数指令也让苹果编译器改了几何边缘像素（门禁 7051 像素差 7 级）。判定进键：表变了要重烘
extrap_of() { local t; for t in "$1"/widen_full.handheld.tsv "$1"/widen_full.docked.tsv; do [ -f "$t" ] && grep -qx 1 "$t" && { echo on; return; }; done; echo off; }
tool_keys() {   # 翻译器 C# 编译闭包键 CS + GAL 翻译代码键 XC（key_of ②③ 与翻译缓存共用）
  if [ -n "${S2A_PREBUILT_TOOLS:-}" ]; then
    # A packaged frontend ships the exact tools built with its engine. Their
    # content manifest replaces MSBuild/clang discovery on the player's Mac.
    # Hash the actual tool closure too: a stale manifest must not reuse a
    # cache after a binary or supporting assembly has been replaced.
    CS=$( (
      set -euo pipefail
      cd "$S2A_PREBUILT_TOOLS"
      [ -f prepare.json ]
      for f in gal/gal_xc shbake/S2A.ShBake shbake/gpu_arch; do [ -x "$f" ]; done
      find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 | shasum -a 256 | cut -c1-64
    ) ) || { echo "🔴 内置工具闭包不完整，算不出缓存键" >&2; return 1; }
    XC=$CS
  else
    # 只取闭包里决定翻译输出的源码（10-24 jhz「不需要的流程一律砍掉」：原先整个 S2A.ShBake 编译闭包 1469 个文件进键——CPU 即时编译 ARMeilleure、Ryujinx.Cpu、
    #   命令处理器、GAL 多线程层、贴图运行时对象……近两天 61 个提交里有 27 个只改这些、却让九款整份重烘）。留：翻译器 Ryujinx.Graphics.Shader / Spv.Generator、
    #   显卡层 Shader/（磁盘缓存格式、特化状态、访问器、翻译入口）与它引的格式 / 描述符 / 目标类型定义、GAL 接口类型（不含 Multithreading/）、
    #   Common 的 Memory/ Utilities/ 与根目录、ShBake 自己、宽屏着色器改写、能力表、各工程与沿途 props / global.json / nuget.config。按代码行算（整行注释不进键）
    local cf cn
    cf=$(python3 "$R/tools/csproj_closure.py" "$R/graphics/tools/shbake/S2A.ShBake.csproj" --files) && [ -n "$cf" ] || { echo "🔴 翻译器闭包算不出（tools/csproj_closure.py）" >&2; return 1; }
    cn=$(printf '%s\n' "$cf" | grep -E '^compat/tree/src/(Ryujinx\.Graphics\.Shader|Spv\.Generator|Ryujinx\.Graphics\.GAL)/|^compat/tree/src/Ryujinx\.Graphics\.Gpu/(Shader/|Image/(FormatInfo|FormatTable|TextureBindingInfo|TextureDescriptor|TextureMsaaMode|TextureTarget)\.cs$|GraphicsConfig\.cs$|Constants\.cs$|[^/]+\.csproj$)|^compat/tree/src/Ryujinx\.Common/(Memory/|Utilities/|[^/]+$)|^compat/tree/[^/]+$|^graphics/tools/shbake/|^graphics/widen/shader/|^graphics/metal/cs/|(^|/)(global\.json|nuget\.config|Directory\.[A-Za-z.]+\.props)$' | grep -v '^compat/tree/src/Ryujinx\.Graphics\.GAL/Multithreading/')
    [ -n "$cn" ] || { echo "🔴 翻译器闭包里没有决定翻译输出的源码（过滤后为空，tools/csproj_closure.py 输出变了？）" >&2; return 1; }
    local kn
    # shellcheck disable=SC2086
    kn=$(python3 "$R/graphics/tools/shbake/key_norm.py" "$R" $cn) || { echo "🔴 翻译器键算不出（graphics/tools/shbake/key_norm.py）" >&2; return 1; }
    CS=$(printf '%s\n%s\n' "$(dotnet --version 2>/dev/null)" "$kn" | shasum -a 256 | cut -c1-16)
    XC=$(bash "$R/graphics/tools/shbake/xc_key.sh") && [ -n "$XC" ] || { echo "🔴 GAL 翻译代码键算不出（graphics/tools/shbake/xc_key.sh）" >&2; return 1; }
  fi
}
# tool_keys 记忆（10-30 出包线 P4「命中路径零等待」，总指挥定口径）：CS / XC 只取决于仓库内容与工具链，同一提交、同一套工具链第二次直接取，
#   省掉 C# 闭包 + key_norm + xc_key 那 3.5–7.6 秒。纯函数记忆、不靠声明输入：记忆键 = HEAD 整棵树号 + DEVELOPER_DIR + Metal / SDK 版本 + dotnet 路径与版本
#   + 会改变 tool_keys 结果的环境变量（S2A_XCKEY_TREE；XLATE_DEBUG / XLATE_REDUCED 防御性带上）。compat/tree、gfx、tools 有未提交改动或未跟踪文件 → 不记忆、照算。
#   S2A_PREBUILT_TOOLS（内置工具）本就只哈希工具目录，不记忆。S2A_TOOLKEYS_MEMO=0 关；缓存目录 S2A_TOOLKEYS_CACHE（缺省 <运行区>/cache/toolkeys）
TK_HOW=
tk_memo_key() {
  { git -C "$R" rev-parse HEAD^{tree} || return 1
    echo "dev=${DEVELOPER_DIR:-} xckey_tree=${S2A_XCKEY_TREE:-} xlate=${XLATE_DEBUG:-}/${XLATE_REDUCED:-}"
    xcrun -sdk iphoneos metal --version 2>&1 | head -1; xcrun --sdk iphoneos --show-sdk-version 2>/dev/null; xcrun --sdk macosx --show-sdk-version 2>/dev/null
    echo "dotnet=$(command -v dotnet) $(dotnet --version 2>/dev/null)"; } | shasum -a 256 | cut -c1-16
}
tool_keys_memo() {
  if [ -n "${S2A_PREBUILT_TOOLS:-}" ] || [ "${S2A_TOOLKEYS_MEMO:-1}" = 0 ]; then TK_HOW=现算; tool_keys; return; fi
  local d mk f
  d=$(git -C "$R" status --porcelain --untracked-files=normal -- compat/tree gfx tools 2> /dev/null) || { TK_HOW="现算（读不到工作树状态）"; tool_keys; return; }
  [ -z "$d" ] || { TK_HOW="现算（工作树有未提交改动，不记忆）"; tool_keys; return; }
  mk=$(tk_memo_key) || { TK_HOW=现算; tool_keys; return; }
  f=${S2A_TOOLKEYS_CACHE:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/cache/toolkeys}/$mk
  if [ -s "$f" ] && read -r CS XC < "$f" && [ -n "${CS:-}" ] && [ -n "${XC:-}" ]; then TK_HOW="命中记忆 $mk"; return 0; fi
  tool_keys || return 1
  mkdir -p "$(dirname "$f")" && printf '%s %s\n' "$CS" "$XC" > "$f.tmp.$$" && mv "$f.tmp.$$" "$f"; TK_HOW="现算并记忆 $mk"
}
key_of() {   # 缓存键 = 真正影响产物的输入（10-21 测试出包线收窄：原先整棵 ryujinx / graphics/metal 树进键，服务层 / 渲染器任何提交都让九款整份重烘）：
  #   ① 游戏输入：romfs / exefs 文件清单 + 大小、exefs/main 内容
  #   ② 翻译器 C# 编译闭包里决定翻译输出的那部分（tool_keys：翻译器、显卡层 Shader/、GAL 接口、ShBake、宽屏着色器改写、能力表；按代码行算）
  #   ③ GAL 翻译代码（graphics/tools/shbake/xc_key.sh：gal_xc 静态链 + 死代码剥离后的二进制哈希，含 SPIRV-Cross；出图 / 绘制等翻译用不到的代码不进键）
  #   ④ 烘焙脚本与工具（shbake 下非 C# 文件、本脚本、gal_offline.py；只算代码行）、统一工具链的 SDK 版本与 metal 编译器版本
  local root=$1 cs xc f sc pp fp
  tool_keys_memo || return 1; cs=$CS; xc=$XC
  # 出哪些对（pack/jobs/archs.py pairs <平台> pso，目标表 + 用途推导；10-29 起替代原先只记 S2A_PSO_ARCHS）：对变了 = 归档变了，必须重烘。
  #   推导不出就报红、不给键（原先 2> /dev/null 吞掉，键里写空对，推导坏了也照样命中旧缓存）
  pp=$("$PY" "$R/pack/jobs/archs.py" pairs "${S2A_PACK_PLAT:-ios}" pso 2> /dev/null) && [ -n "$pp" ] || { echo "🔴 出包目标对推导不出（pack/jobs/archs.py pairs ${S2A_PACK_PLAT:-ios} pso）" >&2; return 1; }
  f=$(git -C "$R" ls-tree -r --name-only HEAD graphics/tools/shbake | grep -v -e '^graphics/tools/shbake/tests/' -e '/obj/' -e '\.cs$' -e '\.csproj$')
  # ④ 按代码行算、不含整行注释 / 空行（graphics/tools/shbake/key_norm.py，10-23 换键批：补注释不再让九款整份重烘）
  # shellcheck disable=SC2086
  sc=$(python3 "$R/graphics/tools/shbake/key_norm.py" "$R" graphics/tools/shader_pack.sh graphics/metal/tools/gal_offline.py $f) && [ -n "$sc" ] || { echo "🔴 烘焙脚本键算不出（graphics/tools/shbake/key_norm.py）" >&2; return 1; }
  fp=$(input_fp "$root") || return 1
  { printf '%s\n' "$fp"
    echo "cs $cs"; echo "xc $xc"; echo "extrap $(extrap_of "$root")"
    echo "scripts $sc"
    [ -z "${S2A_TARGET_DEVICE_CAPS+x}" ] || echo "device-caps $S2A_TARGET_DEVICE_CAPS"
    echo "pso-pairs $(printf '%s\n' "$pp" | tr '\t\n' '. ')"
    if [ -z "${S2A_PREBUILT_TOOLS:-}" ]; then
      xcrun --sdk iphoneos --show-sdk-version 2>/dev/null; xcrun --sdk macosx --show-sdk-version 2>/dev/null
      xcrun -sdk iphoneos metal --version 2>&1 | head -1
    else
      local sdk=iphoneos; [ "${S2A_PACK_PLAT:-ios}" != macos ] || sdk=macosx
      echo "prebuilt-platform $sdk"
      xcrun --sdk "$sdk" --show-sdk-version 2>/dev/null
      xcrun -sdk "$sdk" metal --version 2>&1 | head -1
    fi
    echo "ios${IPHONEOS_DEPLOYMENT_TARGET} macos${MACOSX_DEPLOYMENT_TARGET}"; } | shasum -a 256 | cut -c1-64
}
if [ "${1:-}" = --tool-keys ]; then tool_keys_memo || exit 1; echo "$CS $XC"; echo "$TK_HOW" >&2; exit 0; fi   # 单测 / 排查：打 CS XC，标准错误打命中还是现算
if [ "${1:-}" = --key ]; then [ -d "${2:-}/romfs" ] || { echo "用法：shader_pack.sh --key <产物根>" >&2; exit 2; }; key_of "$2" || exit 1; exit 0; fi
ROOT=${1:?"用法：shader_pack.sh <产物根> <输出目录> [--ref <缓存目录>]…"}; O=${2:?输出目录}; shift 2
REFS=(); while [ $# -gt 0 ]; do case $1 in --ref) REFS+=(--ref "$2"); shift 2;; --ref-guest) REFS+=(--ref-guest "$2"); shift 2;; --ref-bundle) REFS+=(--ref-bundle "$2"); shift 2;; --reflib) REFS+=(--reflib "$2"); shift 2;; *) echo "不认识的参数 $1" >&2; exit 2;; esac; done   # --reflib：参考库 .s2rl（社区缓存的组合关系，见 ShaderBake 4c）；--ref-bundle：yuzu 系客体代码包 .s2gb（pack/stages/shaders.sh 客体缓存阶段传入，#519）
[ -d "$ROOT/romfs" ] && [ -f "$ROOT/main.npdm" ] && [ -f "$ROOT/exefs/main" ] || { t "🔴 $ROOT 不是产物根（缺 romfs/ 或 main.npdm 或 exefs/main）"; exit 2; }
[ -e "$O" ] && [ -n "$(ls -A "$O" 2>/dev/null)" ] && { t "🔴 $O 已有内容：输出目录要新目录（不覆盖）"; exit 2; }
export J=${J:-$(sysctl -n hw.ncpu)}   # 唯一的并行度旋钮（10-20 总指挥：多个出包同跑会超订，出包槽按「核数 ÷ 在跑出包数」设 J）；翻译 -j J、gal_xc / 编库 J、管线分片 J 路（每路单线程）都由它推出
export GAL_XC_J=${GAL_XC_J:-$J}
TID=$($PY -c "import struct,sys;b=open(sys.argv[1],'rb').read();o=struct.unpack_from('<I',b,0x70)[0];assert b[o:o+4]==b'ACI0';print('%016x'%struct.unpack_from('<Q',b,o+0x10)[0])" "$ROOT/main.npdm") || { t "🔴 读不出程序号（main.npdm）"; exit 2; }
PLAT=${S2A_PACK_PLAT:-ios}; [ "$PLAT" = ios ] || [ "$PLAT" = macos ] || { t "🔴 S2A_PACK_PLAT 只认 ios / macos"; exit 2; }
export NXGAL_VPULL=${NXGAL_VPULL:-1}   # 顶点自取（记录位 4 随库走）：基础管线不含顶点布局才能出包预编（gal_vpull.m）；=0 出 GPU 代价对照包（没有管线预编）
# 特化状态运行时化（Ryujinx 补丁 0042 / 0044）：S2A_RUNTIME_STATE=0 出对照包（翻译器透传读取），手机启动环境须给同一取值
W=$O/work; mkdir -p "$W"; T0=$(date +%s)

# 编工具：libnxgal + gal_xc（Mac 版，gal_xc 用）、S2A.ShBake
TB=${S2A_PREBUILT_TOOLS:-$R/build}
if [ -z "${S2A_PREBUILT_TOOLS:-}" ]; then
  make -C "$R/graphics/metal" -s "$R/build/gal/gal_xc" > "$W/build.log" 2>&1 || { t "🔴 编 gal_xc 失败（$W/build.log）"; exit 2; }
  dotnet build -c Release "$R/graphics/tools/shbake/S2A.ShBake.csproj" >> "$W/build.log" 2>&1 || { t "🔴 编 S2A.ShBake 失败（$W/build.log）"; exit 2; }
  clang -fobjc-arc -O1 -o "$R/build/shbake/gpu_arch" "$R/graphics/tools/shbake/gpu_arch.m" -framework Metal -framework Foundation >> "$W/build.log" 2>&1 || { t "🔴 编 gpu_arch 失败（$W/build.log）"; exit 2; }
else
  for f in gal/gal_xc shbake/S2A.ShBake shbake/gpu_arch; do [ -x "$TB/$f" ] || { t "🔴 内置工具缺失：$f"; exit 2; }; done
fi
T1=$(date +%s)

# ① 抽取 + ①b 程序配对 + ①c 透明测试（只读游戏输入与抽取脚本）：按游戏输入 + shbake 下全部 .py + Python 与解包库版本缓存（S2A_SHX_CACHE，缺省 ~/.s2arm/run/s2arm/cache/shx/<程序号>-<键>/），
#   命中就克隆进 work/，不重抽（10-21 测试出包线：键变多是翻译器 / 翻译代码改了，游戏没变；巫师3 / 怪猎每次重抽 97 秒）。每个程序号留最近 2 份
XC=${S2A_SHX_CACHE:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/cache/shx}
IFP=$(input_fp "$ROOT") || exit 1
XK=$TID-$({ printf '%s\n' "$IFP"; cat "$R"/graphics/tools/shbake/*.py "$R"/graphics/tools/nxfmt.py "$R"/graphics/tools/yaz0dec.c; "$PY" --version 2>&1; "$PY" -c 'import lz4; print(lz4.__version__)' 2>&1; } | shasum -a 256 | cut -c1-24)
if [ -f "$XC/$XK/ok" ] && cp -cR "$XC/$XK/." "$W/" && rm -f "$W/ok"; then t "  抽取：缓存命中（$XC/${XK}），不重抽"
else
# 抽着色器只做一次（10-25 jhz）：前面的抽取阶段（pack/stage_extract.sh）出过 <产物根>/extract/（有 ok）就克隆它的 S2Arm 抽取，不重抽（同一份 nxsh_extract、同样含追加内容）；
#   没有（只出通用 S2A_DUAL=0 / 单独调用）就自己抽，追加内容 aoc/<序号>/ 一起扫（原先只扫 romfs，DLC 里的着色器通用兜底没有）
AOCS=(); for a in "$ROOT"/aoc/*/; do [ -d "$a" ] && AOCS+=("${a%/}"); done
if [ -f "$ROOT/extract/ok" ] && [ -s "$ROOT/extract/s2x/rows.tsv" ]; then
  rm -rf "$W/extract" && cp -cR "$ROOT/extract/s2x" "$W/extract" && cp -c "$ROOT/extract/s2x.log" "$W/extract.log" || { t "🔴 克隆抽取阶段的结果失败（$ROOT/extract/s2x）"; exit 1; }
  t "  抽取：用抽取阶段的（$ROOT/extract/s2x），不重抽"
else
  ${TIMEOUT_BIN:+$TIMEOUT_BIN 900 }"$PY" "$R/graphics/tools/shbake/nxsh_extract.py" "$W/extract" "$ROOT/romfs" ${AOCS[@]+"${AOCS[@]}"} --nso "$ROOT/exefs/main" > "$W/extract.log" 2>&1 \
    || { t "🔴 抽取失败（$W/extract.log）"; tail -3 "$W/extract.log"; exit 1; }
fi
[ -s "$W/extract/rows.tsv" ] || { t "🔴 抽取没出 rows.tsv"; exit 1; }
# ①b 程序配对 + 宏取值的静态推导（创新方案一，零游戏配置）：抽到带排列宏的容器（来源标记 @shad）时，从主程序读出「代码实际会建的程序」交给 shbake；
#   工具自己认构造入口，认不到报「本款不适用」、不交表（同主干不配，退回原样）。10-20 暗黑2：程序 26643（全展开）→ 6431，出包 338 秒、792 MB
if grep -q '@shad' "$W/extract/rows.tsv"; then
  ${TIMEOUT_BIN:+$TIMEOUT_BIN 900 }"$PY" "$R/graphics/tools/shbake/exe_programs.py" "$ROOT/exefs/main" "$W/extract/rows.tsv" "$W/programs_exe.tsv" > "$W/programs_exe.log" 2>&1 \
    || { t "🔴 主程序推程序失败（$W/programs_exe.log）"; tail -3 "$W/programs_exe.log"; exit 1; }
fi
# ①b' 外部程序表（S2A_PROG_TABLE，几个读取器的输出拼成一份）：
#   - 容器自带程序表：REDengine shadernx.cache 的材质条目表（graphics/tools/shbake/rdhs_programs.py，全量 vs/ps + 曲面 + 每个 vs 的只顶点程序；10-21 pair 由只接曲面改全量：巫师3 9 局真值 231 个图形程序里 96 个只在这张表里）
#   - 同文件配对：同主干文件名 *_vs.* × *_ps.*、同一压缩流（一个资源文件）里的 vs × ps（graphics/tools/shbake/file_pairs.py；巫师3 SpeedTree、暗黑3 SNO）
#   - UE4 冷冻着色器表（graphics/tools/shbake/ue_programs.py；八方2）
#   - REDengine 静态着色器（graphics/tools/shbake/red_static_programs.py；巫师3 staticshadernx.cache）
#   - 主程序内嵌着色器的描述符表（graphics/tools/shbake/exe_shtab_programs.py；巫师3 界面 Scaleform）
if grep -q 'shadernx.cache@zs' "$W/extract/rows.tsv"; then
  ${TIMEOUT_BIN:+$TIMEOUT_BIN 600 }"$PY" "$R/graphics/tools/shbake/rdhs_programs.py" "$W/extract/rows.tsv" "$ROOT/romfs" -o "$W/programs_rdhs.tsv" --stat --vs-only > "$W/programs_rdhs.log" 2>&1 \
    || { t "🔴 读 shadernx.cache 程序表失败（$W/programs_rdhs.log）"; tail -3 "$W/programs_rdhs.log"; exit 1; }
fi
"$PY" "$R/graphics/tools/shbake/file_pairs.py" "$W/extract/rows.tsv" "$W/programs_files.tsv" 2> "$W/programs_files.log" || { t "🔴 同文件配对失败（$W/programs_files.log）"; exit 1; }
# UE4 冷冻着色器表（graphics/tools/shbake/ue_programs.py，4.25+；八方2）：材质 / 全局表里每支着色器的类型名 + 代码下标 → 按类型族配 vs × ps
if grep -q '@ue0x' "$W/extract/rows.tsv"; then
  ${TIMEOUT_BIN:+$TIMEOUT_BIN 900 }"$PY" "$R/graphics/tools/shbake/ue_programs.py" "$W/extract/rows.tsv" "$ROOT/romfs" "$ROOT/exefs/main" -o "$W/programs_ue.tsv" 2> "$W/programs_ue.log" \
    || { t "🔴 UE 冷冻着色器表配对失败（$W/programs_ue.log）"; tail -3 "$W/programs_ue.log"; exit 1; }
fi
# REDengine 3 静态着色器（graphics/tools/shbake/red_static_programs.py；巫师3 staticshadernx.cache）：主程序里建 CRenderShaderPair 的（.fx, 宏）× 条目键 FNV-1a64 对拍
if grep -q 'staticshadernx.cache@zs' "$W/extract/rows.tsv"; then
  ${TIMEOUT_BIN:+$TIMEOUT_BIN 900 }"$PY" "$R/graphics/tools/shbake/red_static_programs.py" "$ROOT/exefs/main" "$W/extract/rows.tsv" "$ROOT/romfs" -o "$W/programs_red.tsv" 2> "$W/programs_red.log" \
    || { t "🔴 REDengine 静态程序配对失败（$W/programs_red.log）"; tail -3 "$W/programs_red.log"; exit 1; }
fi
# 主程序内嵌着色器的程序表（graphics/tools/shbake/exe_shtab_programs.py；巫师3 界面 Scaleform）：抽到主程序里的顶点 / 片元时，按描述符指针数组 + 组合下标表出程序（认不出 = 本款不适用、不出表）
if grep -q 'nso:[^@]*@adj0x' "$W/extract/rows.tsv"; then
  ${TIMEOUT_BIN:+$TIMEOUT_BIN 600 }"$PY" "$R/graphics/tools/shbake/exe_shtab_programs.py" "$ROOT/exefs/main" "$W/extract/rows.tsv" -o "$W/programs_shtab.tsv" 2> "$W/programs_shtab.log" \
    || { t "🔴 主程序内嵌着色器程序表失败（$W/programs_shtab.log）"; tail -3 "$W/programs_shtab.log"; exit 1; }
fi
# ①c 游戏会不会设透明测试（graphics/tools/shbake/nvn_uses.py，零游戏配置）：所有模块都不调用 nvnColorStateSetAlphaTest 且正对照（BindProgram 有调用）过 →
#   不出透明测试「开」变体（10-20：暗黑2 / 巫师3 不设；动森 / 马车8 / 暗黑3 设；八方2 正对照不过 → 照旧两份）
NU=$(${TIMEOUT_BIN:+$TIMEOUT_BIN 600 }"$PY" "$R/graphics/tools/shbake/nvn_uses.py" "$ROOT/exefs" 2>"$W/nvn_uses.log") || NU='{}'
echo "$NU" > "$W/nvn_uses.json"
mkdir -p "$XC" && rm -rf "$XC/$XK.$$" && mkdir "$XC/$XK.$$" && cp -cR "$W"/extract "$W"/extract.log "$W"/nvn_uses.json "$W"/nvn_uses.log "$XC/$XK.$$/" \
  && { [ ! -e "$W/programs_exe.log" ] || cp -c "$W"/programs_exe.* "$XC/$XK.$$/"; } && { [ ! -e "$W/programs_rdhs.log" ] || cp -c "$W"/programs_rdhs.* "$XC/$XK.$$/"; } && { [ ! -e "$W/programs_files.log" ] || cp -c "$W"/programs_files.* "$XC/$XK.$$/"; } && { [ ! -e "$W/programs_ue.log" ] || cp -c "$W"/programs_ue.* "$XC/$XK.$$/"; } && { [ ! -e "$W/programs_red.log" ] || cp -c "$W"/programs_red.* "$XC/$XK.$$/"; } && { [ ! -e "$W/programs_shtab.log" ] || cp -c "$W"/programs_shtab.* "$XC/$XK.$$/"; } && touch "$XC/$XK.$$/ok" && rm -rf "$XC/$XK" && mv "$XC/$XK.$$" "$XC/$XK" || rm -rf "$XC/$XK.$$"
ls -dt "$XC/$TID"-* 2>/dev/null | grep -v '\.[0-9]*$' | tail -n +3 | while read -r d; do rm -rf "$d"; done
fi
[ -s "$W/programs_exe.log" ] && t "  主程序推程序：$(tail -1 "$W/programs_exe.log")"
# 抽到 0 支（10-27 最终幻想 共鸣 港版：着色器全在 Oodle 压缩的 pak 条目里，抽取器不解 Oodle，唯一键 0）：后面的翻译 / 编库 / 归档都假定至少一支，
#   原先一路走到第 ④ 步 cp gal.*.metallib 找不到文件、「产物复制失败」整包停（直连库在本阶段之后，也没出）。退出 4，交 pack/stages/shaders.sh 只记键、
#   不出通用离线库（同 Vulkan / OpenGL 款）：通用模式运行时首遇编。抽取统计里的「不支持」项（抽取器认得出容器却解不了 = 我方缺口）原样写进
#   work/zero_unsupported.txt 交 shaders.sh 判红 / 黄（空文件 = 包里没有可认的着色器容器）；不让调用方从日志里抠中文原文（10-26 着色器线复审：
#   C 语言环境下 grep 方括号否定按字节匹配，全角标点会截断）
if [ "$(sed -n 's/.*唯一键 \([0-9]*\).*/\1/p' "$W/extract.log" | tail -1)" = 0 ]; then
  python3 -c "import ast,sys
for l in open(sys.argv[1], encoding='utf-8', errors='replace'):
    if l.startswith('统计 '):
        d = ast.literal_eval(l[3:].strip()); print('，'.join(f'{k} {v}' for k, v in d.items() if '不支持' in k and v)); break
else:
    print('抽取统计行读不出')" "$W/extract.log" > "$W/zero_unsupported.txt" 2> /dev/null || echo '抽取统计行读不出' > "$W/zero_unsupported.txt"
  WHY=$(head -1 "$W/zero_unsupported.txt")
  if [ -n "$WHY" ]; then t "🔴 着色器包 ${TID}：抽取 0 支（${WHY}），抽取器缺口，不出通用离线库"
  else t "🟡 着色器包 ${TID}：抽取 0 支（包里没有可认的着色器容器），不出通用离线库"; fi
  exit 4
fi
[ -s "$W/programs_exe.tsv" ] && export S2A_PAIR_TABLE="$W/programs_exe.tsv"
# 外部程序表 S2A_PROG_TABLE = 几个读取器的输出拼成一份（容器程序表 + 同文件配对）
: > "$W/programs_table.tsv"
[ -s "$W/programs_rdhs.log" ] && t "  容器程序表：$(head -1 "$W/programs_rdhs.log")"
[ -s "$W/programs_rdhs.tsv" ] && cat "$W/programs_rdhs.tsv" >> "$W/programs_table.tsv"
[ -f "$W/programs_files.tsv" ] && grep -qv '^#' "$W/programs_files.tsv" && { t "  同文件配对：$(cat "$W/programs_files.log")"; cat "$W/programs_files.tsv" >> "$W/programs_table.tsv"; }
[ -s "$W/programs_ue.tsv" ] && grep -qv '^#' "$W/programs_ue.tsv" && { t "  $(tail -1 "$W/programs_ue.log")"; cat "$W/programs_ue.tsv" >> "$W/programs_table.tsv"; }
[ -s "$W/programs_red.tsv" ] && grep -qv '^#' "$W/programs_red.tsv" && { t "  $(tail -1 "$W/programs_red.log")"; cat "$W/programs_red.tsv" >> "$W/programs_table.tsv"; }
[ -s "$W/programs_shtab.log" ] && t "  $(tail -1 "$W/programs_shtab.log")"
[ -s "$W/programs_shtab.tsv" ] && grep -qv '^#' "$W/programs_shtab.tsv" && cat "$W/programs_shtab.tsv" >> "$W/programs_table.tsv"
grep -qv '^#' "$W/programs_table.tsv" && export S2A_PROG_TABLE="$W/programs_table.tsv"
T2=$(date +%s)
NU=$(cat "$W/nvn_uses.json")
if "$PY" -c "import json,sys;d=json.loads(sys.argv[1]);sys.exit(0 if d.get('ok') and d.get('SetAlphaTest') == 0 else 1)" "$NU"; then export S2A_NO_ALPHA_VARIANTS=1; t "  透明测试：游戏不设（${NU}），不出「开」变体"; else t "  透明测试：${NU}，两份照出"; fi

# ② 翻译 + gal_xc + 写 Ryujinx 缓存（服务器 GC；堆上限 8 GB：旧库 3 GB 上限下动森 283 个程序 OutOfMemory）
# 上限按进度判（10-23，同 ③ 编库）：$W 下连续 S2A_BAKE_STALL_S（缺省 600）秒没有新文件才判卡死（现场 bake.snap），总上限 6 小时；原固定 900 秒在 8 核 Air 上大款翻不完
# 翻译缓存（10-23，S2A_BAKE_CACHE，缺省 ~/.s2arm/run/s2arm/cache/bake/<程序号>-<键>/；=off 关）：翻译只读这些输入，键全按内容算——
#   抽取结果（extract/ 逐文件内容）、翻译器 / gal_xc 键（tool_keys）、平台、外推开关、读帧缓冲变体表、外部程序表 / 配对表、特化管线表（S2A_SPEC_PIPES：补片元输出类型变体读它）、各 --ref / --ref-guest / --reflib 的内容，
#   以及翻译器与 gal_xc 源码里读到的全部环境变量的取值（从源码现扫变量名，新增开关自动进键；扫不到哨兵变量就不缓存）。
#   -j / GAL_XC_J 不进键：产物与并行度无关（马车8 -j 4 / -j 12 逐文件相同）。只缓存 rc=0 的翻译；命中克隆回 work/，不跑翻译器。每个程序号留最近 3 份
BC=${S2A_BAKE_CACHE:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/cache/bake}; BK=
if [ "$BC" != off ] && tool_keys; then
  BENV=$( { find "$R" -name '*.cs' -not -path '*/obj/*' -not -path '*/bin/*' -print0 | xargs -0 grep -ohE 'GetEnvironmentVariable\("[A-Za-z0-9_]+"'
    grep -ohE 'getenv\("[A-Za-z0-9_]+"' "$R"/graphics/metal/tools/gal_xc.c "$R"/graphics/metal/*.m; } | sed -E 's/.*\("//; s/"$//' | LC_ALL=C sort -u | grep -vxE 'HOME|PATH|XDG_SESSION_TYPE|GAL_XC_J')
  if echo "$BENV" | grep -qx S2A_PROG_TABLE && echo "$BENV" | grep -qx NXGAL_VPULL; then
    BK=$TID-$( { echo "cs $CS"; echo "xc $XC"; echo "plat $PLAT extrap $(extrap_of "$ROOT")"
      for v in $BENV; do echo "$v=${!v-（未设）}"; done
      "$PY" - "$W/extract" ${S2A_FBR_VARS:-} ${S2A_PROG_TABLE:-} ${S2A_PAIR_TABLE:-} ${S2A_SPEC_PIPES:-} ${REFS[@]+"${REFS[@]}"} <<'EOF'
import hashlib, os, sys
# 每个参数：文件 = 内容；目录 = 相对路径 + 内容（排序、跟随链接）；--ref 一类开关原样进键
for a in sys.argv[1:]:
    h = hashlib.sha256()
    if os.path.isdir(a):
        fs = sorted(os.path.relpath(os.path.join(d, f), a) for d, _, ff in os.walk(a, followlinks=True) for f in ff)
        for f in fs: h.update(f.encode() + b'\0'); h.update(open(os.path.join(a, f), 'rb').read()); h.update(b'\0')
    elif os.path.isfile(a): h.update(open(a, 'rb').read())
    else: h.update(b'arg:' + a.encode())
    print(h.hexdigest())
EOF
    } | shasum -a 256 | cut -c1-24)
  else t "  翻译缓存：源码里扫不到翻译器的环境变量（S2A_PROG_TABLE / NXGAL_VPULL），不缓存"; fi
fi
if [ -n "$BK" ] && [ -f "$BC/$BK/ok" ] && cp -cR "$BC/$BK/." "$W/" && rm -f "$W/ok"; then BRC=0; mkdir -p "$W/spv"; touch "$BC/$BK"; t "  翻译：缓存命中（$BC/${BK}），不重翻"
else
BPRE=$(ls -A "$W")
DOTNET_gcServer=1 DOTNET_GCHeapHardLimit=0x200000000 S2A_SNAP_STALL="${S2A_BAKE_STALL_S:-600}:$W" bash "$R/graphics/tools/timeout_snap.sh" 21600 "$W/bake.snap" "$TB/shbake/S2A.ShBake" bake "$W/extract" "$W" --title "$TID" -j "$J" \
  --xc "$TB/gal/gal_xc" --plat $PLAT $([ "$(extrap_of "$ROOT")" = off ] && echo --no-extrap) ${S2A_FBR_VARS:+--fbr-vars "$S2A_FBR_VARS"} ${REFS[@]+"${REFS[@]}"} > "$W/bake.log" 2>&1; BRC=$?
# 存缓存：翻译这一步在 work/ 下新出的条目（翻译前已有的抽取 / 程序表不存）；spv/ 不存——下游只有 ③ 编库读它，而 gal_xc 已跑过（GAL_XC_DONE）时编库只读 lib/，马车8 省 1.6 GB
if [ -n "$BK" ] && [ $BRC = 0 ] && [ -f "$W/bake.json" ]; then
  mkdir -p "$BC" && rm -rf "$BC/$BK.$$" && mkdir "$BC/$BK.$$" \
    && (cd "$W" && ls -A | LC_ALL=C sort | LC_ALL=C comm -23 - <(echo "$BPRE" | LC_ALL=C sort) | while IFS= read -r e; do [ "$e" = spv ] || cp -cR "$e" "$BC/$BK.$$/" || exit 1; done) \
    && touch "$BC/$BK.$$/ok" && rm -rf "$BC/$BK" && mv "$BC/$BK.$$" "$BC/$BK" || rm -rf "$BC/$BK.$$"
  ls -dt "$BC/$TID"-* 2>/dev/null | grep -v '\.[0-9]*$' | tail -n +4 | while read -r d; do rm -rf "$d"; done
fi
fi
[ $BRC -le 1 ] && [ -f "$W/bake.json" ] || { t "🔴 翻译失败 rc=${BRC}（$W/bake.log）"; tail -5 "$W/bake.log"; exit 1; }
T3=$(date +%s)

# ②½ 产出指纹（10-24 总指挥「对产物按内容寻址，输出不变就不算变」，graphics/tools/shbake/out_fp.py）：着色器键按工具源码 / 二进制算、偏保守，
#   10-24 审计键变 16 次约一半只改了运行时代码，照样整包重编。这里按包里来自 ② 的全部产出 + ③④ 读到的全部输入算指纹（产出 output.fp），
#   与 S2A_SHADERS_PREV（pack/stage_shaders.sh 给现行包的 shaders/）记下的相同 → 本次出的包与现行逐字节相同，不跑 ③④、退出 3，由调用方沿用现行。
mkdir -p "$O"
OFP=$("$PY" "$R/graphics/tools/shbake/out_fp.py" "$W" "$R" $PLAT "$TID") && echo "$OFP" > "$W/output.fp" || { t "🔴 产出指纹算不出"; exit 1; }
PFP=$(cat "${S2A_SHADERS_PREV:-/nonexistent}/output.fp" 2>/dev/null)
if [ "$PFP" = "$OFP" ]; then t "🟢 着色器包 ${TID}：产出指纹 ${OFP:0:16} 与现行（${S2A_SHADERS_PREV}）相同，不编库 / 管线归档，沿用现行；翻 $((T3-T2)) s"; exit 3; fi
t "  产出指纹 ${OFP:0:16}（现行 ${PFP:+${PFP:0:16}}${PFP:-没记}）：照常编"


# ③ MSL → metallib（gal_xc 已在 ② 跑过）
# 上限按进度判（10-23 用户体验线：8 核 Air 编奥德赛 48286 支撞固定 1800 秒）：$W/lib 下持续有新 .air / metallib 就一直编，连续 S2A_OFFLINE_STALL_S（缺省 600）秒
#   没有新产出才判挂死——超时前抓现场（进程树 + 编译服务栈）写 offline.snap，报最后产出的文件；总上限 6 小时兜底
OSTALL=${S2A_OFFLINE_STALL_S:-600}
GAL_XC_DONE=1 S2A_SNAP_STALL="$OSTALL:$W/lib" bash "$R/graphics/tools/timeout_snap.sh" 21600 "$W/offline.snap" python3 "$R/graphics/metal/tools/gal_offline.py" "$W/spv" "$W/lib" $PLAT > "$W/offline.log" 2>&1; ORC=$?
if [ $ORC != 0 ]; then
  [ $ORC != 124 ] || t "🔴 编 metallib 连续 ${OSTALL} 秒没有新产出（或超 6 小时），判挂死；$(grep -o '已 [0-9]* 秒没有新文件.*最近的文件 [^）]*' "$W/offline.snap" 2> /dev/null | head -1)；现场 $W/offline.snap"
  t "🔴 编 metallib 失败 rc=${ORC}（$W/offline.log）"; tail -3 "$W/offline.log"; exit 1; fi
T4=$(date +%s)

# ④ 基础管线归档（脚本里函数库路径指向产物里的各片 metallib；applegpu-nt 单架构编、不内嵌函数库——metal-tt 会把整个函数库打进去，170 MB / 架构）
mkdir -p "$O"; rm -f "$O"/gal.metallib "$O"/gal.*.metallib; cp -c "$W"/lib/gal.*.metallib "$W/lib/gal.shards" "$W/lib/gal.idx" "$O/" || { t "🔴 产物复制失败"; exit 1; }
# 平均片长 P（条）：缺省 40，S2A_PSO_P 覆盖。10-22 测试机2 巫师3 冷启动（同树、单线程、带低区账本保留量修复，只差片长）：
#   P300 152 片 871.8 MB，拒开 33 片、游戏现建 43、第 120 秒空洞 682 MB；P40 1167 片 901.2 MB，拒开 0、现建 0、第 120 秒空洞 942 MB（1:1 映射按片开，小片开得少）
# 冷片（首用表以外）另按 S2A_PSO_COLD_P（缺省 8）切（pso_gen.py）：10-24 异度神剑3 测试机2 低区 OOM，B2 局证实 iPhone 上放掉归档对象不还映射（管线活着就占着），
#   OOM 局 636 条管线落 118 片、整片 109 MB，只算用到的约 29 MB；其中冷片 81 片只用 1.5 条 / 片、83 MB。冷片切细后归档段每片固定开销约 2% → 9%
# 社区管线状态（ShBake --reflib 写 work/reflib_states.tsv，10-22 总指挥批）：shbake/refpso.py 换算成 v2 行，与收集来的特化管线表（S2A_SPEC_PIPES）合成一张交 pso_gen
SPA=${S2A_SPEC_PIPES:-}
if [ -s "$W/reflib_states.tsv" ]; then
  $PY "$R/graphics/tools/shbake/refpso.py" "$W/reflib_states.tsv" "$O/gal.idx" "$W/reflib_pipes.tsv" > "$W/refpso.log" 2>&1 || { t "🔴 社区管线状态换算失败（$W/refpso.log）"; exit 1; }
  { [ -n "$SPA" ] && [ -s "$SPA" ] && cat "$SPA"; cat "$W/reflib_pipes.tsv"; } | grep -v '^#' | sort -u > "$W/spec_pipes_all.tsv"; SPA=$W/spec_pipes_all.tsv
  t "  社区管线状态：$(tail -1 "$W/refpso.log")"
fi
# 首用表按客体指纹重定位到本包（10-23，shbake/psoremap.py）：表的函数名 = 翻译后 SPIR-V 键，翻译器一改就全对不上（动森 8ebc5d029 包：347 组对上 0，热片 0、提前热 0）。
#   S2A_PSO_KEYMAP（pack/stage_shaders.sh 给：收集目录 <款>/keymap.tsv）先并进本次 键→客体指纹，再把表里本包没有的组合按指纹换成本包程序、重算编码里的程序哈希；
#   结果 work/pso_use.tsv 交 pso_gen（热片）/ psowarm（提前热），并作为包里 shaders/pso_use.tsv（运行时预取）
if [ -n "${S2A_PSO_KEYMAP:-}" ]; then
  $PY "$R/graphics/tools/shbake/psoremap.py" keymap "$W/programs.tsv" "$S2A_PSO_KEYMAP" > "$W/psoremap.log" 2>&1 || { t "🔴 键对照并入失败（$W/psoremap.log）"; exit 1; }
  if [ -n "${S2A_PSO_USE:-}" ] && [ -s "$S2A_PSO_USE" ]; then
    $PY "$R/graphics/tools/shbake/psoremap.py" resolve "$S2A_PSO_USE" "$S2A_PSO_KEYMAP" "$W/programs.tsv" "$W/pso_use.tsv" >> "$W/psoremap.log" 2>&1 || { t "🔴 首用表重定位失败（$W/psoremap.log）"; exit 1; }
    export S2A_PSO_USE=$W/pso_use.tsv; t "  $(tail -1 "$W/psoremap.log")"
  fi
fi
[ -z "${S2A_PSO_USE:-}" ] || [ ! -s "$S2A_PSO_USE" ] || cp "$S2A_PSO_USE" "$O/pso_use.tsv" || { t "🔴 放管线首用表失败"; exit 1; }
# 直连款的通用兜底（S2A_SHADER_NO_PSO=1，10-25 jhz「社区数据要用起来，现在是白算」）：不出每个程序一条的基础管线（全量四千多片），
#   改为只用特化管线表（社区状态换算的 v2 行 + 收回的种子 S2A_SPEC_PIPES）出归档、只编目标设备架构（S2A_PSO_ARCHS）；特化表里一行都没有才整份不编
SPECONLY=0; [ "${S2A_SHADER_NO_PSO:-0}" != 0 ] && [ -n "$SPA" ] && grep -qE '^(v2|b2)[[:space:]]' "$SPA" 2> /dev/null && SPECONLY=1
# Metal 3 老格式归档（#116 / M3-9，S2A_PSO_M3=1，缺省关）：pso_gen 改出 .mtlp-json、pso_chunk 走 metal-tt 出 MTLBinaryArchive。
#   远端（mini）服务只认 .mtl4-json（pso_dist.sh serve 用 applegpu-nt -N），所以开了强制本机编（S2A_PSO_REMOTE=off），
#   否则每片先送到 remote 编失败再退回本机重编，白等一轮。
#   不设时这一段不 export 任何变量，pso_gen / pso_chunk 的环境与产物逐字节不变。
# 出包目标对（10-29 总指挥定口径，pack/jobs/archs.py pairs <平台> pso：目标表 pack/pso_targets.tsv + 按包的用途推导）：
#   每一对 = 一个（GPU 架构, 系统大版本）各出一份归档 gal_pso.<架构>.<平台><大版本>.<片>.bin（运行时按本机架构 + 大版本选，对不上整份不命中）。
#   原先 macOS 只出本机那一个系统大版本、iOS 是架构 × S2A_PSO_OS 的笛卡尔积：本机 macOS 26 出的包在 Air / mini（macOS 27）上「管线归档与本机不匹配」。
#   推导不出 / 有对不在目标表或工具链拒 → 报红退出，不出缺了那台的包
PAIRS=$("$PY" "$R/pack/jobs/archs.py" pairs "$PLAT" pso 2> "$W/pairs.err") || { t "🔴 $(grep '【红】' "$W/pairs.err" | head -1)"; exit 2; }
NP=$(printf '%s\n' "$PAIRS" | grep -c .); N3=$(printf '%s\n' "$PAIRS" | awk -F'\t' '$3 == 3' | grep -c .)
t "  $(tail -1 "$W/pairs.err")：$(printf '%s\n' "$PAIRS" | awk -F'\t' '{printf "%s%s.%s%s（Metal %s）", NR > 1 ? " " : "", $1, P, $2, $3}' P="$PLAT")"
# Metal 3 档（iOS 18 / macOS 15 / A12 A13，目标表 Metal 列 3）要老格式归档：全是 Metal 3 档自动开；两种格式一次出不了（pso_gen 一次只出一种分片），混着就报红、分两次出
[ "$NP" -ge 1 ] || { t "🔴 出包目标推导出 0 对"; exit 2; }
if [ "$N3" -gt 0 ] && [ "$N3" -lt "$NP" ] && [ "${S2A_PSO_M3:-0}" = 0 ]; then
  t "🔴 出包目标里 Metal 3 档 ${N3} 对、Metal 4 档 $((NP - N3)) 对混在一起：通用归档一次只出得了一种格式，请按 Metal 档分两次出（S2A_PSO_ARCHS / S2A_PSO_OS 各给一档）"; exit 2
fi
PSO_M3_ON=0; { [ "${S2A_PSO_M3:-0}" != 0 ] || [ "$N3" = "$NP" ]; } && PSO_M3_ON=1; M3VERS=
if [ "$PSO_M3_ON" = 1 ]; then
  export PSO_M3=1 S2A_PSO_REMOTE=off
  t "  管线归档格式：Metal 3 老格式（.mtlp-json → metal-tt，本批系统大版本各出一份；本机编，mini 不参与）"
fi
S2A_PSO_SPEC_ONLY=$SPECONLY $PY "$R/graphics/tools/shbake/pso_gen.py" "$W/programs.tsv" "$O/gal.idx" "$O/gal.shards" "$W/pso" "${S2A_PSO_P:-40}" "$W/lib/metal_failed.txt" "$W/lib/msl" "$SPA" "$W/fbr.tsv" > "$W/pso_gen.log" 2>&1 || { t "🔴 生成管线脚本失败（$W/pso_gen.log）"; exit 1; }
# 提前热程序表（10-23，shbake/psowarm.py）：首用表里的程序换成本包 Ryujinx 缓存程序号，运行时开机后台先载一次，触发管线预取（Ryujinx 补丁 shader-lazy-warm）
[ -z "${S2A_PSO_USE:-}" ] || [ ! -s "$S2A_PSO_USE" ] || { $PY "$R/graphics/tools/shbake/psowarm.py" "$W/programs.tsv" "$S2A_PSO_USE" "$O/pso_warm.tsv" > "$W/psowarm.log" 2>&1 && t "$(tail -1 "$W/psowarm.log")" || { t "🔴 提前热程序表失败（$W/psowarm.log）"; exit 1; }; }
# 「管线描述 → 归档片号」索引（运行时只开要用的那片归档，graphics/metal/gal_core.m pso_arch_for）
cp -c "$W/pso.idx" "$O/gal_pso.idx" || { t "🔴 管线归档索引复制失败"; exit 1; }
# GPU 二进制绑定系统里的 GPU 编译器：每个（架构, 系统大版本）各出一份，都用统一工具链编（tools/toolchain.env；10-22 jhz 全切 27.1、向下兼容。旧做法按 SDK 大版本在
#   /Applications/Xcode*.app 里挑——10-20 iOS 27 设备拒载 26.5 SDK 出的归档：not compatible with current OS）。函数库（各片 metallib）不随系统版本（AIR 向后兼容），只出一份。
#   出哪些对见上面 PAIRS（pack/jobs/archs.py pairs）
SDKN=$([ $PLAT = ios ] && echo iphoneos || echo macosx)
DD=$DEVELOPER_DIR
PSORED=0; PSOBAD=0; PSO_TOT=0; PSO_RE=0
while IFS=$'\t' read -r A M _ <&3; do
  PC=${GAL_PSO_CACHE:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/gal_pso_cache}; mkdir -p "$PC"
  NT=$(dirname "$(DEVELOPER_DIR=$DD xcrun -f metal-tt)")/../metal/current/bin/applegpu-nt; SV=$(DEVELOPER_DIR=$DD xcrun --sdk $SDKN --show-sdk-version); SP=$(DEVELOPER_DIR=$DD xcrun --sdk $SDKN --show-sdk-path)
  NTV=$("$NT" --version 2>&1 | head -1)
  t "  管线归档 $PLAT ${M}：$(basename "$(dirname "$(dirname "$DD")")") SDK ${SV}，$NTV"
  # 分片并行编（10-20：顺序编时每片只用约 2 核，动森 73 片 233 s）：本机同时 PJ 片（缺省核数 / 2，每片约 1 GB 内存）；失败的片留 .fail 标记
  #   10-21 起本机与 mini 从同一队列领片（graphics/tools/shbake/pso_dist.sh：工作窃取、mini 不可用自动全在本机编；S2A_PSO_REMOTE=off 只用本机）
  # 每个编译进程单线程（PSO_NTJ 缺省 1；设空串 = 编译器自定线程数）、本机并行 J 片（S2A_PSO_J 覆盖）：总核数 = J。
  #   10-21 实测同一片（暗黑3 第 0 片 372 条）缺省线程 8.8 MB 且每次不同、-j 1 4.7 MB 三次逐字节相同：多线程时各线程编出的同一函数二进制各存一份（片内 716 份只有 420 种是独有的）
  PJ=${S2A_PSO_J:-$J}; [ "$PJ" -ge 1 ] || PJ=1
  export PSO_NTJ=${PSO_NTJ-1}
  export PSO_NT=$NT PSO_A=$A PSO_PLAT=$PLAT PSO_M=$M PSO_SV=$SV PSO_SP=$SP PSO_NTV=$NTV PSO_PC=$PC PSO_O=$O PSO_W=$W PSO_PJ=$PJ
  # Metal 3（S2A_PSO_M3=1）：归档最低系统版本必须与运行时系统一致，按本批系统大版本给 <M>.0；不设时不导出，缓存键与产物不变
  #   放在 PSO_SIG 之前：签名里的格式维度直接用 PSO_M3VER，与 pso_chunk 拿到的归档最低系统版本同源（不会出现签名说 27.0、归档按 26.0 的漂移）
  if [ "$PSO_M3_ON" = 1 ]; then export PSO_M3VER="$M.0"; M3VERS="$M3VERS $M.0"; fi
  # 生成器签名含归档格式维度（#116 审阅提醒）：原先只有 pso_gen.py + pso_chunk.sh + Ryujinx CodeGenVersion，
  #   开不开 S2A_PSO_M3 算同一个 PSO_SIG，.mtl4-json（Metal 4）与 .mtlp-json（Metal 3）两种格式的分片缓存会串。
  #   只在本批 M3 开时追加 -m3-<归档最低系统版本>：不设时后缀是空串，PSO_SIG 与改动前逐字节相同（既有缓存不失效、不必重烘）；
  #   设了按系统大版本再分一维（27.0 / 26.0 / 15.0 各一个键，运行时按本机大版本选的那份归档不会命中别的大版本）。
  PSO_M3SIG=; [ "$PSO_M3_ON" = 1 ] && PSO_M3SIG="-m3-$PSO_M3VER"
  export PSO_SIG=$(cat "$R/graphics/tools/shbake/pso_gen.py" "$R/graphics/tools/shbake/pso_chunk.sh" | shasum -a 256 | cut -c1-16)-$(grep -o 'CodeGenVersion = [0-9 +]*' "$R/compat/tree/src/Ryujinx.Graphics.Gpu/Shader/DiskCache/DiskCacheHostStorage.cs" | tr -d ' ')"${PSO_M3SIG}"
  # 分片清单与片数都不经命令行参数（10-24 #100 奥德赛 12572 片：「ls 通配」参数 2.87 MB 超 ARG_MAX 1 MB，退出 126、清单 0 字节，统计也是 0，到零归档检查才红）：
  #   清单用 find（pso_dist.sh list），片数 / 命中数用 shell 内建通配循环数（不起子进程、无参数上限），片数另交 pso_dist 与清单行数核对。没有分片（暗黑3：程序 0）= 什么都不跑，不是失败
  # 两种后缀都数（pso_gen 按 PSO_M3 二者出其一）：只数 .mtl4-json 时 .mtlp-json 的清单行数与 NS 对不上，pso_dist run 直接报红「清单没列全」
  NS=0; for F in "$W"/pso.*.mtl4-json "$W"/pso.*.mtlp-json; do [ -e "$F" ] && NS=$((NS + 1)); done
  if [ "${S2A_SHADER_NO_PSO:-0}" != 0 ] && [ "$SPECONLY" = 0 ]; then t "  管线归档 $A $PLAT${M}：兜底不出（S2A_SHADER_NO_PSO=1、特化表空，$NS 片不编；运行时首遇现建）"
  else
  bash "$R/graphics/tools/shbake/pso_dist.sh" list "$W" "$W/pso_list.txt" || { t "🔴 管线归档 $A $PLAT${M} 列分片失败"; exit 1; }
  bash "$R/graphics/tools/shbake/pso_dist.sh" run "$W/pso_list.txt" "$NS" > "$W/pso_dist.$A.$PLAT$M.log" 2>&1 \
    || { t "🔴 管线归档 $A $PLAT${M}：$(grep '🔴' "$W/pso_dist.$A.$PLAT$M.log" | head -1)"; exit 1; }
  NH=0; for F in "$W"/pso_$A.$PLAT$M.*.hit; do [ -e "$F" ] && NH=$((NH + 1)); done
  t "  管线归档 $A $PLAT${M}$([ "$SPECONLY" = 1 ] && echo "（兜底只编特化表：社区状态 + 种子 $(grep -o '"render": [0-9]*' "$W/pso_gen.log" | tail -1 | grep -o '[0-9]*') 条，按常见度截掉 $(grep -o '"spec_cut": [0-9]*' "$W/pso_gen.log" | tail -1 | grep -o '[0-9]*') 条）")：$NS 片，缓存命中 $NH 片（${PC}）；$(grep '分工：' "$W/pso_dist.$A.$PLAT$M.log" | sed 's/^ *分工：//')"; PSO_TOT=$((PSO_TOT + NS)); PSO_RE=$((PSO_RE + NS - NH))
  grep -q '^  mini：' "$W/pso_dist.$A.$PLAT$M.log" && t "  $(grep '^  mini：' "$W/pso_dist.$A.$PLAT$M.log" | sed 's/^ *//' | tr '\n' ' ' | cut -c1-600)"
  fi
  for F in "$W"/pso_$A.$PLAT$M.*.fail; do
    [ -e "$F" ] || continue
    PSORED=$((PSORED + 1)); L=${F%.fail}.log; t "🔴 管线归档 $A $PLAT$M 第 $(basename "${F%.fail}" | sed 's/.*\.//') 片编译失败（${L}）"; tail -2 "$L"
  done
  # 片里有管线让 applegpu-nt 崩、已隔离（pso_isolate.py）：这片其余照收，坏的逐条算红并点名
  for F in "$W"/pso_$A.$PLAT$M.*.bad; do
    [ -s "$F" ] || continue
    nb=$(wc -l < "$F" | tr -d ' '); PSOBAD=$((PSOBAD + nb)); t "🔴 管线归档 $A $PLAT$M 第 $(basename "${F%.bad}" | sed 's/.*\.//') 片有 $nb 条管线让 applegpu-nt 崩（已隔离、其余照收，这几条首遇现建）：$(head -4 "$F" | tr '\n' ' ')"
  done
done 3< <(printf '%s\n' "$PAIRS")
T5=$(date +%s)
export SP_M3VERS="$M3VERS"   # 读数用（只在 S2A_PSO_M3=1 时有值，shader_pack.json 里也只在该情况出现 pso_m3 键）
M3VERS=

# 产物就位（克隆：同卷不占空间）
mkdir -p "$O/shcache" && cp -cR "$W/shcache/$TID" "$O/shcache/" && cp -c "$W/widen.idx" "$O/" && cp -c "$W/widen_pos.bin" "$O/" && cp -c "$W/guest_keys.tsv" "$O/" || { t "🔴 产物复制失败"; exit 1; }   # widen.idx：画幅线宽屏元数据（e0e7b82）；guest_keys.tsv：客体代码 → 抽取键（双轨 seen，pack/stage_direct.sh 读）
MF=$(grep -c . "$W/lib/metal_failed.txt" 2>/dev/null); MF=${MF:-0}
# 重编支数（10-21：键变了也只重编内容变了的——MSL 按内容缓存 .air、管线分片按所引用函数的库内 HASH 缓存）：gal_offline 的「缓存命中 X，现编 Y」+ 管线分片未命中数
MR=$(grep -oE 'MSL [0-9]+ 支（缓存命中 [0-9]+，现编 [0-9]+）' "$W/offline.log" | tail -1 | grep -oE '[0-9]+' | tr '\n' ' ')
export SP_REBUILT="${MR:-? ? ?} $PSO_TOT $PSO_RE"
PSOBAD=$PSOBAD "$PY" - "$W/bake.json" "$O/shader_pack.json" "$MF" "$TID" $((T1-T0)) $((T2-T1)) $((T3-T2)) $((T4-T3)) "$O" $(du -sk "$O/shcache" | cut -f1) $((T5-T4)) $PSORED "$(tail -1 "$W/pso_gen.log")" <<'E'
import fnmatch, json, os, stat, sys
# 只把目录传进来：上万片的路径不能展开成 argv，也不必读完二进制才能量体积。
# scandir / stat 出错直接失败，不能把枚举失败当作「没有归档」。
sizes = {'gal.*.metallib': 0, 'gal_pso.*.bin': 0}
with os.scandir(sys.argv[9]) as entries:
    for entry in entries:
        for pattern in sizes:
            if fnmatch.fnmatchcase(entry.name, pattern):
                info = entry.stat()
                if not stat.S_ISREG(info.st_mode):
                    raise ValueError(f'不是普通着色器产物：{entry.path}')
                sizes[pattern] += info.st_size
b = json.load(open(sys.argv[1])); red = dict(b.get('red', {})); red['metal_compile'] = int(sys.argv[3]); red['pso_archive'] = int(sys.argv[12]); red['pso_pipeline'] = int(os.environ.get('PSOBAD', '0'))
w = dict(zip(('build_s', 'extract_s', 'bake_s', 'metal_s'), map(int, sys.argv[5:9]))); w['pso_s'] = int(sys.argv[11])
c = b.get('counts', {})
out = {'title': sys.argv[4], 'red': red, 'red_total': sum(red.values()), 'programs_written': c.get('written'), 'programs_total': c.get('programs_total'),
       'spv': c.get('spv_unique'), 'metallib_kb': sizes['gal.*.metallib'] // 1024, 'shcache_kb': int(sys.argv[10]), 'wall_s': w, 'wall_total_s': sum(w.values()),
       'stage_only': b.get('stage_only'), 'known_gap': b.get('known_gap'), 'spec_sources': b.get('spec_sources'), 'bake_wall_ms': b.get('wall_ms'), 'pso': json.loads(sys.argv[13]), 'pso_archive_kb': sizes['gal_pso.*.bin'] // 1024}
out['ref_guest'] = b.get('ref_guest'); out['reflib'] = b.get('reflib'); out['spec_trimmed_tex_queries'] = b.get('spec_trimmed_tex_queries')   # 继承条目按再翻收窄掉的贴图查询位（10-23，九款逐款读数）   # 收回的运行时缓存 / 参考库各配了多少、对不上多少（工作目录收尾时删，读数只在这里留）
if os.environ.get('PSO_M3') == '1':   # Metal 3 老格式归档（S2A_PSO_M3=1）：只在这种情况下加键，不设时读数与产物逐字节不变
    out['pso_m3'] = {'format': 'mtlp-json', 'encoder': 'metal-tt', 'min_versions': os.environ.get('SP_M3VERS', '').split()}
rb = os.environ.get('SP_REBUILT', '').split()
out['rebuilt'] = {'msl': int(rb[2]) if rb[2:3] and rb[2].isdigit() else None, 'msl_total': int(rb[0]) if rb[:1] and rb[0].isdigit() else None,
                  'pso_chunks': int(rb[4]) if rb[4:5] else None, 'pso_chunks_total': int(rb[3]) if rb[3:4] else None}
json.dump(out, open(sys.argv[2], 'w'), ensure_ascii=False, indent=1)
print(json.dumps({k: out[k] for k in ('red', 'known_gap', 'programs_written', 'spv', 'rebuilt', 'metallib_kb', 'shcache_kb', 'pso', 'pso_archive_kb', 'wall_s')}, ensure_ascii=False))
E
[ $? = 0 ] || { t "🔴 着色器包统计失败（$O/shader_pack.json）"; exit 1; }
key_of "$ROOT" > "$O/shader_pack.key"; echo "$OFP" > "$O/output.fp"
NRED=$($PY -c "import json,sys;print(json.load(open(sys.argv[1]))['red_total'])" "$O/shader_pack.json")
t "$([ "$NRED" = 0 ] && echo 🟢 || echo 🔴) 着色器包 ${TID}（${PLAT}）：红 ${NRED}；重编 MSL $(echo "$SP_REBUILT" | cut -d' ' -f3) / $(echo "$SP_REBUILT" | cut -d' ' -f1) 支、管线 $PSO_RE / $PSO_TOT 片；$(tail -1 "$W/bake.log" | cut -c1-200)；墙钟 编 $((T1-T0)) s / 抽 $((T2-T1)) s / 翻 $((T3-T2)) s / 编库 $((T4-T3)) s / 管线 $((T5-T4)) s → $O"
[ "$NRED" = 0 ]
