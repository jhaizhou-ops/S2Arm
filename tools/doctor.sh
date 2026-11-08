#!/bin/bash
# 开发环境只读体检（贡献者自检 tools/contrib_check.sh 的第一步，也可单跑）：bash tools/doctor.sh
# 只读：不装、不改、不下载。要求一律从仓库现有文件读，不另立版本表——
#   Xcode / 部署目标：tools/toolchain.env；.NET SDK：compat/tree/global.json（sdk.version + rollForward）；
#   Python 第三方包：tools/rewriter-requirements.txt（解释器 S2A_PY：环境 → tools/machine.local → PATH 上的 python3，同出包各阶段；一键准备 python3 launchers/macos/prepare_build.py 建 venv 并装齐）。
#   Python ≥ 3.12、bash ≥ 5 没有版本文件：Python 是 tools 里 Python 段用了 3.12 起才允许的 f-string 写法（3.9 跑 ab.sh 报 SyntaxError，10-23 实测）；
#   bash 是门禁 / 列车按 Homebrew bash 5 写和测的（macOS 自带 /bin/bash 3.2 有「$变量紧跟中文」等已知差异，见 tests/shell_lint_test.sh）。
# 输出：每项一行「✅ / ❌ 名称：本机读数（要求，来源）」，缺的给能照做的安装命令；末尾每个缺项打一行「缺：<名称>」（contrib_check 按它跳过依赖该工具的步骤）。
# 退出码：0 全齐；1 有缺项。
set -u
cd "$(git rev-parse --show-toplevel 2> /dev/null)" || { echo "请在 S2Arm 仓库里跑"; exit 1; }
MISS=()
ok() { echo "✅ $1：$2"; }
bad() { echo "❌ $1：$2"; echo "   → $3"; MISS+=("$1"); }

# bash
if [ "${BASH_VERSINFO[0]:-0}" -ge 5 ]; then ok "bash 5" "${BASH_VERSION}（要求 ≥ 5，门禁 / 列车按 Homebrew bash 写和测）"
else bad "bash 5" "${BASH_VERSION}（要求 ≥ 5）" "brew install bash，再用 /opt/homebrew/bin/bash 跑 tools/contrib_check.sh"; fi

# Python
PV=$(python3 -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])' 2> /dev/null)
if python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 12) else 1)' 2> /dev/null; then ok "Python 3.12+" "python3 = ${PV}（$(command -v python3)）"
else bad "Python 3.12+" "python3 = ${PV:-没有}（要求 ≥ 3.12：tools 里的 Python 段用了 3.12 起的 f-string 写法）" "brew install python@3.12，确认 which python3 指向它（macOS 自带 3.9）"; fi

# Python 第三方包（钉死版本）
PY=${S2A_PY:-$(bash tools/machine.sh get S2A_PY 2> /dev/null)}; PY=${PY:-$(command -v python3)}; RQ=tools/rewriter-requirements.txt
if [ -f "$RQ" ]; then
  if [ -n "$PY" ] && [ -x "$PY" ]; then
    bad_pk=; while IFS= read -r l; do l=${l%%#*}; l=$(echo "$l" | tr -d ' '); [ -n "$l" ] || continue
      n=${l%%==*}; want=${l#*==}; have=$("$PY" -c "import $n; print($n.__version__)" 2> /dev/null)   # 与 graphics/widen/scan/wide_scan.py 同口径：模块自报版本
      [ "$have" = "$want" ] || bad_pk="$bad_pk ${n}（要 ${want}，本机 ${have:-没装}）"; done < "$RQ"
    if [ -z "$bad_pk" ]; then ok "Python 包" "$RQ 全部对上（${PY}）"
    else bad "Python 包" "版本不符：${bad_pk}（${RQ}）" "$PY -m pip install -r $RQ"; fi
  else bad "Python 包" "没有 ${PY}（改写器 / 宽屏扫描用的固定解释器）" "python3 launchers/macos/prepare_build.py（建 venv、装齐钉版依赖），再按它最后打印的那行 export S2A_PY=…"; fi
fi

# Xcode：同出包的工具链解析（tools/toolchain.sh：启动器 / 本机指定 → xcode-select → toolchain.env 缺省），只查能力不查版本号（10-25 jhz「不应该限定」）
TCO=$( (S2A_TC_QUIET=1; source tools/toolchain.sh && echo "${DEVELOPER_DIR}｜iOS SDK ${S2A_TC_SDK}｜${S2A_TC_METAL}") 2>&1 | tail -1)
case $TCO in 🔴*) bad "Xcode" "${TCO#🔴 }" "装 Xcode 并打开一次完成组件安装（iOS 平台、Metal Toolchain）；装了多个时 sudo xcode-select -s <Xcode.app>/Contents/Developer，或设 S2A_DEVELOPER_DIR";;
  *) ok "Xcode" "$(DEVELOPER_DIR=${TCO%%｜*} xcodebuild -version 2> /dev/null | head -1)：${TCO}";; esac

# .NET SDK：compat/tree/global.json
GJ=compat/tree/global.json
SW=$(python3 -c "import json; d=json.load(open('$GJ'))['sdk']; print(d['version'], d.get('rollForward', 'patch'))" 2> /dev/null)
if [ -n "$SW" ]; then
  set -- $SW; WV=$1; RF=$2
  # 与构建脚本（services/nxaot.sh、一键出包）用同一个 dotnet：DOTNET → ~/.dotnet → PATH；只看 PATH 会在 Air 这类 PATH 里没有 dotnet 的机器上误报
  DN=${DOTNET:-$HOME/.dotnet/dotnet}; [ -x "$DN" ] || DN=$(command -v dotnet || true)
  SDKS=$([ -n "$DN" ] && "$DN" --list-sdks 2> /dev/null | awk '{print $1}')
  hit=$(python3 - "$WV" "$RF" $SDKS <<'PY'
import sys
w, rf, have = sys.argv[1], sys.argv[2], sys.argv[3:]
def t(v): a = v.split('-')[0].split('.'); return int(a[0]), int(a[1]), int(a[2]) // 100, int(a[2]) % 100
W = t(w)
for h in have:
    H = t(h)
    if rf == 'latestFeature' and H[:2] == W[:2] and (H[2], H[3]) >= (W[2], W[3]): print(h); break
    if rf in ('patch', 'latestPatch') and H[:3] == W[:3] and H[3] >= W[3]: print(h); break
    if rf in ('latestMinor', 'minor') and H[0] == W[0] and H[1:] >= W[1:]: print(h); break
    if rf in ('latestMajor', 'major') and H >= W: print(h); break
PY
)
  # SDK 根（--list-sdks 给的真实位置）；源码构建版（如 Homebrew）自带的 macOS NativeAOT 运行时包没有 Brotli 静态库，编 Mac 版 C# 库链接缺 _Brotli*（10-24 #100 D01），判据与 services/nxaot.sh 链接前那道检查相同
  DROOT=$([ -n "$hit" ] && "$DN" --list-sdks 2> /dev/null | sed -n "s/^${hit} \[\(.*\)\]$/\1/p" | head -1); DROOT=${DROOT%/sdk}
  NOBR=; for p in "$DROOT"/packs/Microsoft.NETCore.App.Runtime.NativeAOT.osx-arm64/*/runtimes/osx-arm64/native; do
    [ -f "$p/libSystem.IO.Compression.Native.a" ] && [ ! -f "$p/libbrotlienc.a" ] && NOBR=$p; done
  if [ -n "$hit" ] && [ -n "$NOBR" ]; then bad ".NET 10 SDK" "dotnet SDK ${hit} 在 ${DROOT}，是源码构建版（如 Homebrew）：自带的 NativeAOT 运行时包没有 Brotli 静态库，编 Mac 版 C# 库会报 _Brotli* 未定义" "改用微软官方 SDK：curl -sSL https://dot.net/v1/dotnet-install.sh | bash -s -- --version ${WV}（装到 ~/.dotnet），再 export DOTNET=~/.dotnet/dotnet DOTNET_ROOT=~/.dotnet PATH=~/.dotnet:\${PATH}（Homebrew 版可以留着）"
  elif [ -n "$hit" ]; then ok ".NET 10 SDK" "dotnet SDK ${hit}（${DN}；要求 ${WV}、rollForward ${RF}，${GJ}）"
    # 读取器等 .NET 程序的启动壳（apphost）只认 DOTNET_ROOT 或微软默认位置 /usr/local/share/dotnet；仓库脚本自己会补，直接跑这些工具前要 export（10-24 #100 D01）
    [ -n "${DOTNET_ROOT:-}" ] || [ "$DROOT" = /usr/local/share/dotnet ] || echo "ℹ️ DOTNET_ROOT 没设：一键出包 / 门禁会自己补；直接跑读取器等 .NET 工具前先 export DOTNET_ROOT=${DROOT}（写进 shell 的启动配置一劳永逸）"
  else bad ".NET 10 SDK" "已装 SDK：$(echo $SDKS | tr ' ' ',' | sed 's/^$/没有/')（要求 ${WV}、rollForward ${RF}，${GJ}）" "curl -sSL https://dot.net/v1/dotnet-install.sh | bash -s -- --version ${WV}，再把 ~/.dotnet 加进 PATH"; fi
fi

# C 改写器固定依赖（钉版 Capstone / LZ4 源码，runtime/rewriter/prepare_deps.py 生成；构建不自动下载）：
#   查法直接调 pack/rewriter.py 的 dependency_dir()（S2A_REWRITER_DEPS → build/rewriter-deps → ${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/deps/rewriter-deps），不另抄一份顺序。
#   10-27 PR #505 贡献者：doctor 全绿、快测却在「出包：改写」红，被当成游戏问题误报。指定 S2A_REWRITER_C 时不需要
if [ -n "${S2A_REWRITER_C:-}" ]; then ok "改写器固定依赖" "不需要（S2A_REWRITER_C 已指定）"
elif RD=$(python3 -c 'import sys; sys.path.insert(0, "pack"); import rewriter; print(rewriter.dependency_dir())' 2> /dev/null); then ok "改写器固定依赖" "${RD}（Capstone 5.0.7 / LZ4 4.4.5，runtime/rewriter/README.md）"
else bad "改写器固定依赖" "S2A_REWRITER_DEPS、build/rewriter-deps、${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/deps/rewriter-deps 都没有完整的钉版 Capstone / LZ4 源码（缺了出包「改写」一步必红，不是游戏问题）" \
  "python3 runtime/rewriter/prepare_deps.py build/rewriter-deps（只联网下载这一次；多棵工作树共用一份的放法见 runtime/rewriter/README.md）"; fi

# 部署目标（只报，不判）
echo "ℹ️ 部署目标：$(grep -E '^(MACOSX|IPHONEOS)_DEPLOYMENT_TARGET=' tools/toolchain.env | tr '\n' ' ')（tools/toolchain.env，构建脚本自动带）"
for m in ${MISS[@]+"${MISS[@]}"}; do echo "缺：$m"; done
[ ${#MISS[@]} = 0 ]
