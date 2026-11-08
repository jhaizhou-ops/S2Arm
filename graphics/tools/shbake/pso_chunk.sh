#!/bin/bash
# 编一片基础管线归档（shader_pack.sh ④ 经 pso_dist.sh 调）：bash pso_chunk.sh <pso.N.mtl4-json>          命中拷出 / 不中本机现编
#                                                       bash pso_chunk.sh --hit <pso.N.mtl4-json>    只查缓存：命中拷出退出 0，不中退出 3（不编）
#                                                       bash pso_chunk.sh --put <pso.N.mtl4-json> <归档>  别处（mini）编好的归档：放进产物目录 + 按本机算的键写缓存
# 内容寻址缓存（10-20：暖轮 .air 全命中时管线段仍 169 s）：键 = sha256(分片键 <pso.N.key>（pso_gen：脚本去掉库路径 + 引用函数在 metallib 函数表里的 HASH 标签）
#   + 工具链版本 PSO_NTV + 架构 PSO_A + 平台大版本 PSO_PLAT$PSO_M + SDK 版本 PSO_SV + 生成器签名 PSO_SIG（pso_gen.py / 本脚本内容 + Ryujinx CodeGenVersion）+ 编译线程数 PSO_NTJ（设了才进））。
#   归档按描述 + 引用函数的库内 HASH 命中，与库文件 / 库里别的函数无关（10-21 实测，见 pso_gen.py 头注释）：10-20 的 PSO_LIBH（全部 gal.*.metallib 的哈希）
#   一支着色器变就全部分片重编（马车8 91 片 237 s），已由分片键里的库内 HASH 取代——编库参数 / 编译器 / 链接序改了函数位码，HASH 跟着变，键照样变。
# 任一成员变 = 不命中（graphics/tools/shbake/tests/t_pso_cache.sh 逐项反证）。没有分片键（老 pso_gen / 函数表读不出）= 不用缓存，照编。
#   --put 的键只在本机算：mini 编的归档与本机编的按运行时描述同样命中（pso_dist.sh 头注释的探针实测），远端工具链版本 / SDK 版本与 PSO_NTV / PSO_SV 逐字相同才派（pso_dist.sh serve 核）。
# 环境：PSO_NT（applegpu-nt）PSO_A PSO_PLAT PSO_M PSO_SV PSO_SP（sysroot）PSO_NTV PSO_SIG PSO_NTJ（-j 线程数，空 = 编译器缺省）PSO_PC（缓存目录）PSO_O（产物目录）PSO_W（工作目录，写 .log / .fail / .hit）
set -u
# 超时保护（#591）：macOS 默认没有 timeout。用仓库的 perl 版 tools/bin/timeout（tools/toolchain.sh 放到 PATH 最前，本脚本由 shader_pack.sh 拉起、继承 PATH；.app 的 Runtime/bin/timeout 是它的拷贝）。取不到就直接跑、只提示一次，
#   绝不因为缺 timeout 判失败——原来 `if ! timeout 600 …` 在没 timeout 的机器上让 `timeout: command not found` 返回 127，
#   被 if ! 当成「编译失败」：写 .fail、exit 0，产物 0 个，外面看着像跑完了（Metal 3 归档 / 老格式归档两条分支都中招）。
#   ${TIMEOUT_BIN:+$TIMEOUT_BIN 600 } 故意不加引号：空时展开成空（不包超时），非空时按空格切成「<bin> 600」两个词。
#   只用 command -v 声明随包命令（timeout 在 launchers/macos/bundle_runtime.py 的 TOOLS 里，tests/userenv_test.sh ① 只认这些）；
#   gtimeout 是 Homebrew coreutils 的带前缀名，本机可选，用 type -P 探（取不到照样直接跑）。
TIMEOUT_BIN=$(command -v timeout || true)
[ -n "$TIMEOUT_BIN" ] || TIMEOUT_BIN=$(type -P gtimeout || true)
if [ -z "$TIMEOUT_BIN" ] && { mkdir "$PSO_W/.no_timeout" 2> /dev/null || [ ! -d "$PSO_W/.no_timeout" ]; }; then
  echo "pso_chunk：本机没有 timeout（coreutils 的 timeout / gtimeout），跳过超时保护，编译照跑" >&2
fi
MODE=; case ${1:-} in --hit|--put) MODE=$1; shift;; esac
S=$1; b=${S%.*}; n=${b##*.}; KF=$b.key   # 两种扩展名（.mtl4-json / .mtlp-json）都按最后一段取片号：pso.3.mtlp-json → 3
# Metal 3 的平台 SDK 与编译器版本（后者进缓存键）：脚本与库要按目标平台出，不能写死 macosx
M3_SDK=macosx; [ "${PSO_PLAT:-}" = ios ] && M3_SDK=iphoneos
M3_TV=
[ -n "${PSO_M3:-}" ] && M3_TV=$(xcrun -sdk "$M3_SDK" metal-tt -version 2>/dev/null | head -1)
TAG=$PSO_A.$PSO_PLAT$PSO_M.$n; OUT=$PSO_O/gal_pso.$TAG.bin; CF=
if [ -s "$KF" ]; then
  # 线程数 PSO_NTJ 也进键（10-21 实测：同一片缺省线程 8.8 MB 且每次不同、-j 1 4.7 MB 逐字节相同，产物随线程数变）；不设时不加这一行，缺省版的键与旧缓存一致
  # Metal 3 维度（PSO_M3 / 最低系统版本 / metal-tt 版本）也进键：不加的话同一条管线在两种格式间会互相命中对方产物
  K=$({ printf '%s\n%s\n%s\n%s\n%s\n%s\n' "$(cat "$KF")" "$PSO_NTV" "$PSO_A" "$PSO_PLAT$PSO_M" "$PSO_SV" "$PSO_SIG"
         [ -n "${PSO_M3:-}" ] && printf 'm3\n%s\n%s\n' "${PSO_M3VER:-}" "$M3_TV"
         [ -n "${PSO_NTJ:-}" ] && printf 'j%s\n' "$PSO_NTJ"; } | shasum -a 256 | cut -c1-64)
  CF=$PSO_PC/${K:0:2}/$K.bin
  # 命中后 touch -c 刷新条目修改时间：克隆不刷新访问时间，gc（tools/gc.sh）按最近使用删、1 小时内用过不动都靠它
  if [ "$MODE" != --put ] && [ -s "$CF" ]; then cp -c "$CF" "$OUT" && touch "$PSO_W/pso_$TAG.hit" && { touch -c "$CF"; exit 0; }; fi
fi
put_cache() { if [ -n "$CF" ] && [ -s "$OUT" ]; then mkdir -p "${CF%/*}" && cp -c "$OUT" "$CF.$$.tmp" && mv "$CF.$$.tmp" "$CF"; fi; }
# 本机编译只写工作目录里的临时件 TMP，成功才改名成正式归档 OUT（审计 #872 F-pso-timeout-partial：原先直接 -o "$OUT"，编译器写到一半被超时杀掉 / 崩掉 / 隔离也失败时
#   半截归档留在产物目录，shader_pack 把它当这片的归档收进部分包、阶段键记下后不再重烘）。失败一律 fail_chunk：删临时件、写 .fail；产物目录里不会出现没编完的归档。
#   临时件放 PSO_W（产物目录下的 work/，出包前整个删掉）：本进程被外面杀掉时残件也进不了包
TMP=$PSO_W/pso_$TAG.$$.bin
fail_chunk() { rm -f "$TMP"; touch "$PSO_W/pso_$TAG.fail"; exit 0; }
take_chunk() { mv "$TMP" "$OUT" || fail_chunk; }   # 编译退出 0 却没有输出也按失败（mv 找不到临时件）
case $MODE in
  --hit) exit 3;;
  --put) [ -s "${2:-}" ] && cp "$2" "$OUT.$$.tmp" && mv "$OUT.$$.tmp" "$OUT" || exit 1; put_cache; exit 0;;
esac
# PSO_NTJ：每个编译进程的线程数（applegpu-nt -j）；不给 = 编译器自定（一个进程可吃满多核，并行几路时总核数不受控）
# Metal 3（.mtlp-json，PSO_M3=1）：老格式脚本不走 applegpu-nt -N，改由 metal-tt 读取配置脚本及其声明的各片库。
#   库路径由脚本 libraries.paths 与函数 alias 引用解析；最低系统版本必须与运行时系统一致（实测：27.0 命中，26.0 / 15.0 不命中），由 PSO_M3VER 给。
if [ -n "${PSO_M3:-}" ]; then
  [ -n "${PSO_M3VER:-}" ] || { echo "PSO_M3VER 必填：归档最低系统版本必须与运行时系统一致" > "$PSO_W/pso_$TAG.log"; fail_chunk; }
  # 库由脚本内 alias 引用解析，不再作为位置参数重复生成和打包。
  # 「air-tt: No available translator」根因（docs/坑记录.md 10-29 shdist 那条）：air-tt 的翻译器查询缓存每用户一份、文件名不认版本，本机两套 Metal 工具链互相冲掉。
  #   metal-tt 子进程带 DIRHELPER_USER_DIR_SUFFIX=s2a-tt-<工具链版本>（统一入口 tools/tt_env.sh tt_suffix；版本取不到报红、按整片失败，不给空后缀）。
  #   只给这个子进程，不导出：宿主运行时的 Metal 系统缓存也在用户缓存目录里。
  #   重试只兜底：只对这一句重试、至多 5 次、退避加抖动，其余失败照旧立即判失败。S2A_METAL_TT：单测换假工具（graphics/tools/shbake/tests/t_pso_tt_retry.sh）
  M3TT=(xcrun -sdk "$M3_SDK" metal-tt); M3TTP=$(xcrun -sdk "$M3_SDK" -f metal-tt 2> /dev/null)
  [ -n "${S2A_METAL_TT:-}" ] && { M3TT=("$S2A_METAL_TT"); M3TTP=$S2A_METAL_TT; }
  . "$(cd "$(dirname "$0")/../../.." && pwd)/tools/tt_env.sh" && M3TTS=$(tt_suffix "$M3TTP" 2>> "$PSO_W/pso_$TAG.log") || fail_chunk
  for a in 0 1 2 3 4 5; do
    ${TIMEOUT_BIN:+$TIMEOUT_BIN 600 }env DIRHELPER_USER_DIR_SUFFIX="$M3TTS" "${M3TT[@]}" -arch "$PSO_A" "-$PSO_PLAT-version-min" "$PSO_M3VER" "$S" -o "$TMP" > "$PSO_W/pso_$TAG.log" 2>&1 && break
    { [ $a = 5 ] || ! grep -q 'No available translator' "$PSO_W/pso_$TAG.log"; } && fail_chunk
    echo "pso_chunk：metal-tt 找不到翻译器（并发偶发），第 $((a + 1)) 次重试" >> "$PSO_W/pso_$TAG.retry"
    sleep "$(awk -v a=$a -v r=$RANDOM 'BEGIN { printf "%.2f", 0.2 * (a + 1) + r / 32767 * 0.2 }')"
  done
  take_chunk; put_cache; exit 0
fi
NTA=("$PSO_NT" -arch "$PSO_A" -platform_version "$PSO_PLAT" "$PSO_M.0" "$PSO_SV" -sysroot "$PSO_SP")
[ -n "${PSO_NTJ:-}" ] && NTA+=(-j "$PSO_NTJ")
${TIMEOUT_BIN:+$TIMEOUT_BIN 600 }"${NTA[@]}" -N "$S" -o "$TMP" > "$PSO_W/pso_$TAG.log" 2>&1; rc=$?
# 整片编译超时（timeout 退出 124）= 编译异常，不是有坏管线：直接整片失败、不进隔离（审计 #806 第 4 条后续：原先进隔离，首次试编同一整片再白等一轮 600 秒才失败）
if [ $rc = 124 ] && [ -n "$TIMEOUT_BIN" ]; then echo "pso_chunk：整片编译超时（600 秒）：超时不等于有坏管线，不进隔离，按整片失败" >> "$PSO_W/pso_$TAG.log"; fail_chunk; fi
if [ $rc != 0 ]; then
  # 整片编失败：隔离让编译器崩的那几条（pso_isolate.py），其余照收；坏的清单写 .bad（shader_pack.sh 报红点名）。隔离过的不进缓存：下次照样隔离、照样报红，不靠缓存命中把红吞掉
  #   只有一条管线的片不隔离（整片就是那一条，隔离只多一次 Python 启动；负载高时远端每片失败都多这几秒，t_pso_dist ⑥⑦ 时序更紧）
  if [ "$(grep -oE '"(vertex|compute)_function_descriptor"' "$S" | wc -l)" -ge 2 ]; then
    python3 "$(cd "$(dirname "$0")" && pwd)/pso_isolate.py" "$S" "$TMP" "$PSO_W/pso_$TAG.bad" -- "${NTA[@]}" >> "$PSO_W/pso_$TAG.log" 2>&1 || { rm -f "$PSO_W/pso_$TAG.bad"; fail_chunk; }
    take_chunk; exit 0
  fi
  fail_chunk
fi
take_chunk; put_cache
exit 0
