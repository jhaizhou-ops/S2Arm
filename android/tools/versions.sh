# Android 固定组件版本的唯一来源（#1131 复审第 1 条）：docker/Dockerfile 的
# ARG SDK_PACKAGES。宿主脚本一律 source 本文件，不再各自写字面量；docker 镜像
# 内 /src 同路径可读同一份；doctor.py 自解析同一行做一致性核对。
#
# source 后得到：
#   S2A_ANDROID_PLATFORM（android-36）/ S2A_ANDROID_BUILD_TOOLS / S2A_ANDROID_NDK /
#   S2A_ANDROID_CMAKE / S2A_ANDROID_SDK_PACKAGES（原样 "name;ver" 列表）
#   s2a_sdkmanager_hint [sdk 目录] —— 产出一行可复制执行、包名加引号的 sdkmanager 命令
#     （cmdline-tools/latest 不存在时落回 PATH 里的 sdkmanager 名）。

_s2a_versions_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
_s2a_pkgs=$(sed -n 's/^ARG SDK_PACKAGES="\(.*\)"$/\1/p' "$_s2a_versions_dir/docker/Dockerfile" | head -n 1)
if [ -z "$_s2a_pkgs" ]; then
    echo "【红】无法从 android/docker/Dockerfile 解析 ARG SDK_PACKAGES" >&2
    return 1 2>/dev/null || exit 1
fi
S2A_ANDROID_SDK_PACKAGES=$_s2a_pkgs
for _s2a_pkg in $_s2a_pkgs; do
    case ${_s2a_pkg%%;*} in
    platforms)   S2A_ANDROID_PLATFORM=${_s2a_pkg#*;} ;;
    build-tools) S2A_ANDROID_BUILD_TOOLS=${_s2a_pkg#*;} ;;
    ndk)         S2A_ANDROID_NDK=${_s2a_pkg#*;} ;;
    cmake)       S2A_ANDROID_CMAKE=${_s2a_pkg#*;} ;;
    *) echo "【红】ARG SDK_PACKAGES 含未登记组件：$_s2a_pkg" >&2
       return 1 2>/dev/null || exit 1 ;;
    esac
done
: "${S2A_ANDROID_PLATFORM:?Dockerfile SDK_PACKAGES 缺 platforms}" \
  "${S2A_ANDROID_BUILD_TOOLS:?Dockerfile SDK_PACKAGES 缺 build-tools}" \
  "${S2A_ANDROID_NDK:?Dockerfile SDK_PACKAGES 缺 ndk}" \
  "${S2A_ANDROID_CMAKE:?Dockerfile SDK_PACKAGES 缺 cmake}"
export S2A_ANDROID_PLATFORM S2A_ANDROID_BUILD_TOOLS S2A_ANDROID_NDK S2A_ANDROID_CMAKE \
       S2A_ANDROID_SDK_PACKAGES

s2a_sdkmanager_hint() {
    local sdk=${1:-${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}} mgr quoted=
    [ -n "$sdk" ] || sdk=$HOME/Library/Android/sdk
    mgr=$sdk/cmdline-tools/latest/bin/sdkmanager
    [ -x "$mgr" ] || mgr=sdkmanager
    for _s2a_pkg in $S2A_ANDROID_SDK_PACKAGES; do
        quoted="$quoted \"$_s2a_pkg\""
    done
    printf '"%s" --sdk_root="%s"%s\n' "$mgr" "$sdk" "$quoted"
}

unset _s2a_versions_dir _s2a_pkgs _s2a_pkg
