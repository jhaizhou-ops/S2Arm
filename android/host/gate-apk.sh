#!/usr/bin/env bash
# Offline APK gate for the native-host Android build (#1131): same contract as
# docker/gate-apk.sh — verify the preparation receipt, copy the tracked source
# into a disposable snapshot, then build with all network access denied
# (sandbox-exec on macOS). Dependencies must already be in S2A_BUILD_CACHE;
# run host/prepare.sh first. Missing or mismatched preparation is red with the
# install/prepare commands (owner rule), never a silent skip.
set -euo pipefail
android_dir=$(cd "$(dirname "$0")/.." && pwd -P)
repo_dir=$(cd "$android_dir/../.." && pwd -P)
red() { printf '【红】安卓宿主 APK 门禁：%s\n' "$1" >&2; exit 1; }
# 宿主门禁只在 macOS 有意义（sandbox-exec 断网、NDK darwin prebuilt）；Linux 主机走
# docker 后端，本步骤不适用直接过。
[ "$(uname -s)" = Darwin ] || { echo '宿主 APK 门禁不适用非 macOS 宿主（Linux 走 docker 后端）'; exit 0; }
cd "$android_dir"
command -v python3 >/dev/null || red '缺 python3'
. "$android_dir/tools/versions.sh"
sdk_hint=$(s2a_sdkmanager_hint "${ANDROID_HOME:-$HOME/Library/Android/sdk}")
command -v sandbox-exec >/dev/null \
    || red '缺 sandbox-exec：宿主门禁无法强制离线（需要 macOS 10.15+ 的 /usr/bin/sandbox-exec）'
. "$android_dir/tools/ndk_toolchain.sh"
. "$android_dir/host/hostenv.sh"
ndk=$(s2a_ndk_resolve) || red "找不到固定 NDK（ANDROID_NDK_HOME 或 ANDROID_HOME/ndk/${S2A_ANDROID_NDK}）；安装：${sdk_hint}"
ndk_bin=$(s2a_ndk_host_bin "$ndk") || red "NDK $ndk 没有本宿主可用的 prebuilt bin"
sdk_version=$(sed -n 's/^sdk_version=\([0-9.]*\).*/\1/p' "$android_dir/cs/build.sh" | head -1)
[ -n "$sdk_version" ] || red '无法读取 cs/build.sh 的 sdk_version'
dotnet=${S2A_ANDROID_DOTNET:-$S2A_BUILD_CACHE/dotnet/$sdk_version/dotnet}
expected=$(python3 "$android_dir/docker/cache-identity.py" --backend host \
    --repo "$repo_dir" --source "$repo_dir" --sdk "$ANDROID_HOME" --ndk "$ndk" \
    --dotnet "$dotnet" --javac "$JAVAC") || red '依赖清单不可核实'
# 只核准备标记（S2A_APK_RECEIPT_CHECK=1，同 docker/gate-apk.sh）：相符退 0、缺 / 不匹配退 42
need() { [ "${S2A_APK_RECEIPT_CHECK:-}" != 1 ] || { printf '需备料：%s\n' "$1"; exit 42; }; }
# 缺本身份准备完成标记 = 缺依赖：直接报红并给备料命令（owner：不报「未跑」装绿）。
# 只认本依赖身份槽；别的身份（别的树、已变依赖）槽不参与判断。
receipt_path=$S2A_BUILD_CACHE/$(printf '%s\n' "$expected" \
    | python3 "$android_dir/docker/cache-identity.py" --slot) || red '依赖清单不可核实'
# Distinguish an absent receipt from a broken one; never follow a link.
[ ! -L "$receipt_path" ] || red '准备完成标记是符号链接'
if [ ! -e "$receipt_path" ]; then
    need '缺准备完成标记'
    red "缺准备完成标记：宿主依赖未备料或环境不匹配。先按固定版本装齐 Android 组件（${sdk_hint}），再运行 bash android/host/prepare.sh"
fi
[ -f "$receipt_path" ] || red '准备完成标记不是常规文件'
receipt=$(cat "$receipt_path")
[ "$receipt" = "$expected" ] \
    || { need '准备标记与宿主环境或依赖不匹配'; red '准备标记与宿主环境或依赖不匹配；运行 bash android/host/prepare.sh'; }
[ "${S2A_APK_RECEIPT_CHECK:-}" != 1 ] || { echo '准备标记与当前依赖清单相符'; exit 0; }
# 凭据校验成功后登记本槽的使用时间：prepare 按最近使用保留 4 个槽，日常只跑门禁
# 的身份（main）不会被接连 prepare 的分支挤掉。
[ ! -L "$receipt_path" ] && [ -f "$receipt_path" ] && touch "$receipt_path" \
    || red '无法登记准备凭据使用时间'
start=$SECONDS
scratch=$(mktemp -d "${HOME}/s2a-apk-gate.XXXXXXXX")
trap 'rc=$?; rm -rf "$scratch"; echo "安卓宿主 APK 门禁墙钟：$((SECONDS - start)) 秒（rc=${rc}）"' EXIT
# The working-tree bytes, including tracked local edits, are the inputs under
# test. Never copy ignored outputs or an untracked game tree.
python3 - "$repo_dir" "$scratch/src" <<'PY'
import os, pathlib, shutil, subprocess, sys
root, target = map(pathlib.Path, sys.argv[1:])
for raw in subprocess.check_output(['git', '-C', str(root), 'ls-files', '-z']).split(b'\0'):
    if not raw:
        continue
    rel = os.fsdecode(raw)
    src, dst = root / rel, target / rel
    dst.parent.mkdir(parents=True, exist_ok=True)
    if src.is_symlink():
        dst.symlink_to(os.readlink(src))
    else:
        shutil.copy2(src, dst)
PY
# All caches come from S2A_BUILD_CACHE (receipt-certified); the sandbox profile
# denies every network operation so a missing dependency is red, not fetched.
rc=0
# deny network* 连 unix socket / 本机回环一起掐死：MSBuild 带外 task host 用 unix socket
# （MSB4216），Gradle FileLockContentionHandler 要 bind loopback（SocketException）。
# 只放 unix-socket 进出 + loopback 的 bind/accept/connect，实测 8.8.8.8、nuget.org 仍拒
# （10-31，python 直连验证）。
# JVM 缺省走 IPv6 双栈：绑 / 连 127.0.0.1 实际是 IPv4 映射地址 ::ffff:127.0.0.1，沙箱的
# "localhost" 不认（host 只能写 * 或 localhost，没法单放映射地址），Gradle 守护连接器 bind
# 报 Operation not permitted。JAVA_TOOL_OPTIONS 让沙箱里每个 JVM（客户端、单次守护、worker）
# 都走纯 IPv4 栈，回环就是真 127.0.0.1（11-02 实测）。macOS 的 JDK 把系统代理设置灌成
# socksProxyHost / http(s).proxyHost=127.0.0.1，走真回环后能经本机代理出网，同一处清空。
sandbox-exec -p '(version 1)(allow default)(deny network*)'\
'(allow network* (local unix-socket)(remote unix-socket))'\
'(allow network-bind (local ip "localhost:*"))'\
'(allow network-inbound (local ip "localhost:*"))'\
'(allow network-outbound (remote ip "localhost:*"))' \
env "HOME=$S2A_BUILD_CACHE/home" \
    "ANDROID_HOME=$ANDROID_HOME" "ANDROID_SDK_ROOT=$ANDROID_SDK_ROOT" \
    "JAVA_HOME=$JAVA_HOME" "S2A_JAVAC=$JAVAC" "JAVA_TOOL_OPTIONS=-Djava.net.preferIPv4Stack=true -DsocksProxyHost= -Dhttp.proxyHost= -Dhttps.proxyHost= -Dftp.proxyHost=" \
    "S2A_BUILD_CACHE=$S2A_BUILD_CACHE" "NUGET_PACKAGES=$NUGET_PACKAGES" \
    "GRADLE_USER_HOME=$GRADLE_USER_HOME" "ANDROID_USER_HOME=$ANDROID_USER_HOME" \
    ${S2A_ANDROID_DOTNET:+"S2A_ANDROID_DOTNET=$S2A_ANDROID_DOTNET"} \
    "S2ARM_ANDROID_CS_SERVICES=static" "S2ARM_ANDROID_GAME_DIR=" "RyuGpu=" \
    bash -c '
      set -euo pipefail
      src=$1; ndk_bin=$2
      cd "$src/platforms/android"
      mkdir -p "$HOME" "$GRADLE_USER_HOME" "$ANDROID_USER_HOME"
      source docker/gate-step.sh
      s2a_apk_step bash cs/build.sh
      s2a_apk_step bash openssl/build.sh
      s2a_apk_step ./gradlew --offline --no-daemon \
          --project-cache-dir "$src/build/android-gradle-project" :app:assembleDebug
      s2a_apk_step python3 docker/gate-audit.py --root "$src" --ndk-bin "$ndk_bin"
      s2a_apk_step python3 verify-apk.py app/build/outputs/apk/debug/app-debug.apk
    ' _ "$scratch/src" "$ndk_bin" > "$scratch/host.log" 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then
    reason=$(grep -m1 '^【红】APK ' "$scratch/host.log" || true)
    if [ -z "$reason" ]; then
        reason=$(grep -v '^[[:space:]]*$' "$scratch/host.log" | tail -1 || true)
        reason="【红】APK 宿主构建失败（rc=${rc}）：${reason:-无诊断输出}"
    fi
    printf '%s\n' "$reason" >&2
fi
cat "$scratch/host.log"
if [ "$rc" -eq 0 ] && [ -n "${S2A_APK_OUT:-}" ]; then
    cp "$scratch/src/platforms/android/app/build/outputs/apk/debug/app-debug.apk" "$S2A_APK_OUT"
fi
if [ "$rc" -eq 0 ]; then
    printf '已证宿主项\t安卓宿主\tapk\n'
fi
exit "$rc"
