#!/usr/bin/env bash
# 同一工作树两路各构建一次再按批准口径比对（#1131 复审第 4 条）：
#   1. docker/gate-apk.sh 离线容器构建 → backend-docker.apk
#   2. host/gate-apk.sh   离线宿主构建 → backend-host.apk（仅 macOS arm64）
#   3. tools/compare_apks.py 用宿主 NDK 的 llvm-nm 逐条比对
# 两路门禁各自核实准备完成标记、断网构建并做 APK 验签；本脚本只负责
# 依序驱动与收集产物。docker 路缺镜像/缓存时 gate 会按契约 skip（exit 0），
# 此时产物不存在——对「两路都必须真跑」的驱动来说就是红，不静默放行。
#
# 用法：bash android/tools/compare_backends.sh <输出目录>
set -euo pipefail
tools_dir=$(cd "$(dirname "$0")" && pwd -P)
android_dir=$(dirname "$tools_dir")
out_dir=${1:?用法：bash android/tools/compare_backends.sh <输出目录>}
mkdir -p "$out_dir"
out_dir=$(cd "$out_dir" && pwd -P)
red() { printf '【红】两路比对：%s\n' "$1" >&2; exit 1; }
rev=$(git -C "$android_dir" rev-parse --short=9 HEAD 2>/dev/null || echo '?')
dirty=$(git -C "$android_dir" status --porcelain 2>/dev/null | head -1)
echo "比对工作树：${rev}${dirty:+（含未提交改动）}"

run_gate() {  # $1=产物路径 $2=门禁脚本 $3=路名 $4=日志
    local apk_out=$1 gate=$2 label=$3 log=$4
    rm -f "$apk_out"
    S2A_APK_OUT="$apk_out" bash "$gate" > "$log" 2>&1 \
        || { rc=$?; cat "$log"; red "${label}门禁失败（rc=${rc}），完整日志 ${log}"; }
    # gate 可以 exit 0 但什么也没产出（docker 路缺件时按契约 skip）：
    # 对比对驱动而言两路都必须真跑，缺产物即红。
    [ -f "$apk_out" ] || { cat "$log"; red "${label}未产出 APK（缺准备件被 skip？），完整日志 ${log}"; }
}

run_gate "$out_dir/backend-docker.apk" "$android_dir/docker/gate-apk.sh" 'docker 路' "$out_dir/docker-gate.log"
run_gate "$out_dir/backend-host.apk" "$android_dir/host/gate-apk.sh" '宿主路' "$out_dir/host-gate.log"

. "$tools_dir/ndk_toolchain.sh"
ndk=$(s2a_ndk_resolve) || red '找不到固定 NDK（无法定位 llvm-nm）'
ndk_bin=$(s2a_ndk_host_bin "$ndk") || red "NDK $ndk 没有本宿主可用的 prebuilt bin"
[ -x "$ndk_bin/llvm-nm" ] || red "找不到 llvm-nm：$ndk_bin/llvm-nm"

exec python3 "$tools_dir/compare_apks.py" \
    --left "$out_dir/backend-docker.apk" --right "$out_dir/backend-host.apk" \
    --nm "$ndk_bin/llvm-nm"
