#!/bin/bash
# 工具链解析：source 后导出本次出包用的那套 Xcode（DEVELOPER_DIR，xcrun / clang / devicectl / metal 都跟着它走）与解析结果，不满足硬下限就返回 1。
#   用法：source "$R/tools/toolchain.sh" || exit 2
# 按用户机器实际装的走，不写死版本（10-25 jhz：「得根据用户实际安装的版本走，这个数据可以从咱们前端启动器取到……不应该限定」）：
#   选哪个 Xcode：① S2A_DEVELOPER_DIR（前端启动器传进来的：检测到的已装 Xcode 与用户选择，缺省最新，见 pack/jobs/toolchain.py detect_xcode；
#      也可以在 tools/machine.local 里给本机定）② 装着的 Xcode 里最新的（同 detect_xcode）③ xcode-select 当前指向；都没有 → 报红「目录不在」（不退到仓库里写的版本）。
#   解析一次、全程共用（10-25：一键出包外层 refresh 与 ipa.sh 里的 refresh 各取各的，Metal 版本不同进了直连库键，整份出两遍）：
#      解析结果导出成 S2A_TC_RESOLVED=1、S2A_TC_METAL（iOS Metal 编译器版本）、S2A_TC_SDK（iOS SDK 版本）、S2A_PSO_OS（目标 iOS 大版本：
#      启动器按连着的 iPhone 给了就用，否则取 SDK 大版本），子进程再 source 时直接沿用、不再各取。各阶段键只读这几个变量。
#   能力检查，不查版本号：有 iOS SDK、有 Metal 编译器（Xcode 的 Metal Toolchain 组件）、SDK 不低于产物下限 IPHONEOS_DEPLOYMENT_TARGET；缺什么就说什么。
#   Makefile 不经这里：认导出的 S2A_DEVELOPER_DIR / DEVELOPER_DIR（这里解析完一并导出，make 跟着同一套），都没有按 xcode-select
_tcd=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# 超时一律用仓库的 perl 版 tools/bin/timeout（10-28：GNU timeout 自立进程组，嵌套时外层按组杀不到内层——出包撞 nchain 2 小时上限后
#   direct_lib 成孤儿续写盘 2 小时；perl 版留在调用方组里、收信号转给子组）。规则只在 tools/_timeout.sh 一处，这里 source 它；
#   放在最前、早于「上游已解析就沿用」的返回，每次 source 都生效
{ [ -f "$_tcd/_timeout.sh" ] && . "$_tcd/_timeout.sh"; } || :
# 产物最低系统版本：macOS 下限导出（clang 编宿主没给 -mmacosx-version-min 时按它定 minos，不随编译机系统版本变）；
#   iOS 下限只设 shell 变量、不导出——两个都导出时 clang 不带 -target 编宿主会当成 iOS（10-22 实测：宿主目标文件 minos 18.0、报 sysroot 不配），
#   iOS 编译一律显式带下限（runtime/build.mk -target、graphics/metal IOS_FLAGS、gal_offline / shader_pack / opus / vpx 读 toolchain.env）
MACOSX_DEPLOYMENT_TARGET=$(sed -n 's/^MACOSX_DEPLOYMENT_TARGET=//p' "$_tcd/toolchain.env"); export MACOSX_DEPLOYMENT_TARGET
MSBUILDDISABLENODEREUSE=$(sed -n 's/^MSBUILDDISABLENODEREUSE=//p' "$_tcd/toolchain.env"); export MSBUILDDISABLENODEREUSE   # 构建完不留 MSBuild 常驻节点
IPHONEOS_DEPLOYMENT_TARGET=$(sed -n 's/^IPHONEOS_DEPLOYMENT_TARGET=//p' "$_tcd/toolchain.env")
# 本机编译缓存跟编译器走（审计 #1534 P1-107）：壳编号跨平台、不含编译器（Windows 出包机没有 Xcode 也要算得出），所以 Mac 本地的壳缓存与
#   iOS 编译中间产物另记「出它们那次的工具链版本行」（Metal 编译器 + iOS clang），版本行不同（真换了 Xcode / Metal 组件；没有记录的旧缓存同样算）就当没命中、重出一次。
#   定义在「上游已解析：沿用」之前，沿用时也有
s2a_tc_fp() { printf '%s｜%s\n' "${S2A_TC_METAL:-}" "$(xcrun --sdk iphoneos clang --version 2> /dev/null | sed -n 1p)"; }
s2a_tc_same() { [ "$(cat "$1" 2> /dev/null)" = "$(s2a_tc_fp)" ]; }   # s2a_tc_same <记录文件>：记录 = 本机工具链 → 0
# s2a_tc_sweep <记录文件> <目录…>：记录与本机工具链不同 → 删掉这些缓存目录（先改名再删，删到一半不留半截目录在原位）、写新记录；相同 → 不动
s2a_tc_sweep() { local f=$1 d; shift; s2a_tc_same "$f" && return 0
  for d in "$@"; do [ -e "$d" ] || continue; mv "$d" "$d.stale.$$" && rm -rf "${d:?}.stale.$$" || return 1; done
  mkdir -p "$(dirname "$f")" && s2a_tc_fp > "$f"; }
if [ "${S2A_TC_RESOLVED:-}" = 1 ] && [ -d "${DEVELOPER_DIR:-}" ] && [ -n "${S2A_TC_METAL:-}" ]; then unset _tcd; return 0 2> /dev/null || exit 0; fi   # 上游已解析：沿用
[ -n "${S2A_DEVELOPER_DIR:-}" ] || . "$_tcd/machine.sh" 2> /dev/null   # 本机私有的选择（machine.local 里的 S2A_DEVELOPER_DIR）
if [ -n "${S2A_DEVELOPER_DIR:-}" ]; then _tcv=$S2A_DEVELOPER_DIR; _tcw="指定（S2A_DEVELOPER_DIR：前端启动器 / 本机配置）"
# 没指定 → 装着的 Xcode 里版本最新的一个（含 xcode-select 指的那个），与启动器缺省同一条规则、同一份实现（pack/jobs/toolchain.py detect_xcode）。
#   11-07 Duo 定因：原先退到 xcode-select（本机指 Xcode 26.5），会话里没设 S2A_DEVELOPER_DIR 就用 26.5 SDK 出壳，iOS 27 新机型（iPhone Duo）
#   上整个 App 按旧 iPhone 尺寸 667×375 缩小居中；新 SDK 链接才认得新机型。缺省取最新，不靠各线记得设环境变量
#   S2A_XCODE_SEARCH：找 Xcode 的目录（冒号分隔，缺省 /Applications 与 ~/Applications；单测指假的）
elif _tcv=$("${S2A_PY:-python3}" -c 'import os, sys; sys.path.insert(0, sys.argv[1]); from toolchain import detect_xcode; d = os.environ.get("S2A_XCODE_SEARCH"); print(detect_xcode(*([d.split(":")] if d else []), select="xcode-select") or "")' "$_tcd/../pack/jobs" 2> /dev/null) && [ -d "$_tcv" ]; then _tcw="缺省：装着的 Xcode 里最新的"
elif _tcv=$(xcode-select -p 2> /dev/null) && [ -d "$_tcv" ]; then _tcw="xcode-select 当前指向（找不到 /Applications 下的 Xcode）"
else _tcv=; _tcw="没指定、也找不到装着的 Xcode"; fi   # 不再退到仓库里写的版本（10-25 总指挥：全仓不写死 Xcode 路径 / 版本）
_tcr() { echo "🔴 打 iPhone 包的 Xcode 不能用：$1（选中的是 ${_tcv:-无}，来源 ${_tcw}）。$2" >&2; [ -z "${_tcm_errf:-}" ] || rm -f "$_tcm_errf"; unset DEVELOPER_DIR _tcd _tcv _tcw _tcs _tcm _tcm_out _tcm_rc _tcm_errf _tcm_bad _tcl; return 1; }
[ -d "${_tcv:-}" ] || { _tcr "目录不在" "去 App Store 安装 Xcode，打开一次完成组件安装；装了多个时在启动器里选一个。"; return 1 2> /dev/null || exit 1; }
_tcs=$(DEVELOPER_DIR=$_tcv xcrun --sdk iphoneos --show-sdk-version 2> /dev/null)
[ -n "$_tcs" ] || { _tcr "没有 iOS SDK" "打开 Xcode → Settings → Components，装上 iOS 平台。"; return 1 2> /dev/null || exit 1; }
# Metal 探测同时核三样（#403：缺组件的 shim 会退出 0 却打 error，旧写法只看首行非空，把错误输出当成功）：
#   ① 命令退出状态 0——先取状态再解析输出，不接管道，不让 head / grep 把状态吞掉；② stdout 有合法版本行（Apple metal version <数字>，不要求第一行）；
#   ③ stdout / stderr 都没有 error 文本。缺任一样按「没有 Metal 编译器」拒绝。
_tcm_errf=${TMPDIR:-/tmp}/s2a-tc-metal.$$.err
_tcm_rc=0
_tcm_out=$(DEVELOPER_DIR=$_tcv xcrun -sdk iphoneos metal --version 2> "$_tcm_errf") || _tcm_rc=$?
_tcm=; _tcm_bad=0
while IFS= read -r _tcl; do
  case $_tcl in "Apple metal version "[0-9]*) _tcm=$_tcl; break;; esac
done <<< "$_tcm_out"
case $_tcm_out in *[Ee][Rr][Rr][Oo][Rr]*) _tcm_bad=1;; esac
if grep -qi 'error' "$_tcm_errf" 2> /dev/null; then _tcm_bad=1; fi
if [ "$_tcm_rc" -ne 0 ] || [ -z "$_tcm" ] || [ "$_tcm_bad" = 1 ]; then
  _tcr "没有 Metal 编译器" "打开 Xcode → Settings → Components，装上 Metal Toolchain（或启动器里点「一键下载」）。"; return 1 2> /dev/null || exit 1
fi
rm -f "$_tcm_errf"
[ "${_tcs%%.*}" -ge "${IPHONEOS_DEPLOYMENT_TARGET%%.*}" ] 2> /dev/null || { _tcr "iOS SDK ${_tcs} 低于产物下限 iOS ${IPHONEOS_DEPLOYMENT_TARGET}" "把 Xcode 更新到能出 iOS ${IPHONEOS_DEPLOYMENT_TARGET} 以上的版本。"; return 1 2> /dev/null || exit 1; }
DEVELOPER_DIR=$_tcv; S2A_DEVELOPER_DIR=$_tcv; S2A_TC_SDK=$_tcs; S2A_TC_METAL=$_tcm; S2A_PSO_OS=${S2A_PSO_OS:-${_tcs%%.*}}; S2A_TC_RESOLVED=1
export DEVELOPER_DIR S2A_DEVELOPER_DIR S2A_TC_SDK S2A_TC_METAL S2A_PSO_OS S2A_TC_RESOLVED
[ -n "${S2A_TC_QUIET:-}" ] || echo "S2Arm 工具链：${_tcv}（${_tcw}）；iOS SDK ${_tcs}、${_tcm}；目标 iOS ${S2A_PSO_OS}" >&2
unset _tcd _tcv _tcw _tcs _tcm _tcm_out _tcm_rc _tcm_errf _tcm_bad _tcl
