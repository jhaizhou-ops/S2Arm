# Android 宿主构建环境（#1131）：SDK 解析 + 固定包核对 + JDK 17 + 缓存目录 +
# .NET 透传。build.sh / prepare.sh / gate-apk.sh 共用；固定版本字面量由
# doctor.requirements 核对，防静默漂移。source 后得到：
#   ANDROID_HOME/ANDROID_SDK_ROOT、JAVA_HOME、JAVAC、S2A_BUILD_CACHE、
#   NUGET_PACKAGES、GRADLE_USER_HOME、ANDROID_USER_HOME、
#   PATH（JDK + build-tools + platform-tools 前置）。
# .NET：S2A_ANDROID_DOTNET 显式指定时只规范化为绝对路径；版本核对在 cs/build.sh。

hostenv_fail() { echo "🔴 $*" >&2; exit 1; }

hostenv_android_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
. "$hostenv_android_dir/tools/versions.sh"
# SDK 路径解析只有 pack/targets/android/package.py 的 android_sdk_home 一处
# （#1207 复审三条）：ANDROID_HOME → ANDROID_SDK_ROOT → local.properties 的
# sdk.dir（多行末行生效、值取 = 后整行可含空格）→ Darwin ~/Library/Android/sdk
# → 其它 ~/Android/Sdk。本脚本不再各自解析，避免与出包口径漂移。
hostenv_repo=$(cd "$hostenv_android_dir/.." && pwd -P)
hostenv_py=${S2A_PY:-${PY:-python3}}
[ -f "$hostenv_repo/pack/targets/android/package.py" ] \
    || hostenv_fail "缺 $hostenv_repo/pack/targets/android/package.py（SDK 路径解析唯一实现）"
hostenv_sdk=$("$hostenv_py" - "$hostenv_repo" <<'PY_SDK'
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "pack", "targets", "android"))
from package import android_sdk_home
print(android_sdk_home(dict(os.environ)))
PY_SDK
) || hostenv_fail "SDK 路径解析失败：$hostenv_py 调 package.py android_sdk_home 非零退出"
if [ ! -d "$hostenv_sdk" ]; then
    hostenv_fail "找不到 Android SDK：${hostenv_sdk}
  先建目录再装命令行工具与固定版本包（任选其一得到 sdkmanager，包名含分号必须加引号）：
    mkdir -p \"$hostenv_sdk\"
    macOS:   brew install --cask android-commandlinetools   # sdkmanager 进 PATH
    或直接:  https://developer.android.com/studio#command-line-tools 下载 cmdline-tools 解压成 $hostenv_sdk/cmdline-tools/latest
    $(s2a_sdkmanager_hint "$hostenv_sdk")
  已有装齐的 SDK 时改设 ANDROID_HOME，或在 $hostenv_android_dir/local.properties 写 sdk.dir=..."
fi
hostenv_sdk=$(cd "$hostenv_sdk" && pwd -P)
export ANDROID_HOME=$hostenv_sdk ANDROID_SDK_ROOT=$hostenv_sdk
# 门禁只读：不写 local.properties。写回 sdk.dir 只在显式的 prepare.sh / build.sh
# 里做（#1207 复审二条：门禁路径不能往源码树写文件）。

hostenv_missing=()
[ -d "$hostenv_sdk/platforms/$S2A_ANDROID_PLATFORM" ] || hostenv_missing+=("platforms;$S2A_ANDROID_PLATFORM")
[ -x "$hostenv_sdk/build-tools/$S2A_ANDROID_BUILD_TOOLS/apksigner" ] || hostenv_missing+=("build-tools;$S2A_ANDROID_BUILD_TOOLS")
[ -d "$hostenv_sdk/ndk/$S2A_ANDROID_NDK" ] || hostenv_missing+=("ndk;$S2A_ANDROID_NDK")
[ -d "$hostenv_sdk/cmake/$S2A_ANDROID_CMAKE" ] || hostenv_missing+=("cmake;$S2A_ANDROID_CMAKE")
if [ ${#hostenv_missing[@]} -gt 0 ]; then
    hostenv_fail "SDK $hostenv_sdk 缺固定版本包：${hostenv_missing[*]}
  装：$(s2a_sdkmanager_hint "$hostenv_sdk")"
fi

JAVAC=$(bash "$hostenv_android_dir/tools/jdk17.sh" || true)
[ -n "$JAVAC" ] || hostenv_fail "找不到 JDK 17 的 javac（按宿主装）：
  macOS:          brew install openjdk@17
  Debian/Ubuntu:  apt install openjdk-17-jdk-headless
  Fedora:         dnf install java-17-openjdk-devel
  Arch:           pacman -S jdk17-openjdk
  或用 S2A_JAVAC=<javac 绝对路径> 指定"
JAVA_HOME=$(cd "$(dirname "$JAVAC")/.." && pwd -P)
export JAVA_HOME
export PATH=$JAVA_HOME/bin:$hostenv_sdk/build-tools/$S2A_ANDROID_BUILD_TOOLS:$hostenv_sdk/platform-tools:$PATH

if [ -z "${S2A_BUILD_CACHE:-}" ] && [ -z "${HOME:-}" ]; then
    hostenv_fail "构建缓存需要 HOME 或显式设置 S2A_BUILD_CACHE"
fi
export S2A_BUILD_CACHE=${S2A_BUILD_CACHE:-$HOME/.cache/s2arm-build}
mkdir -p "$S2A_BUILD_CACHE"
export NUGET_PACKAGES=${NUGET_PACKAGES:-$S2A_BUILD_CACHE/nuget}
export GRADLE_USER_HOME=${GRADLE_USER_HOME:-$S2A_BUILD_CACHE/gradle}
export ANDROID_USER_HOME=${ANDROID_USER_HOME:-$S2A_BUILD_CACHE/android-user}

if [ -n "${S2A_ANDROID_DOTNET:-}" ]; then
    [ -x "$S2A_ANDROID_DOTNET" ] || hostenv_fail "S2A_ANDROID_DOTNET 不可执行：$S2A_ANDROID_DOTNET"
    export S2A_ANDROID_DOTNET=$(cd "$(dirname "$S2A_ANDROID_DOTNET")" && pwd -P)/$(basename "$S2A_ANDROID_DOTNET")
fi
unset hostenv_sdk hostenv_missing
