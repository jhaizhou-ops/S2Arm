#!/usr/bin/env bash
# 安卓服务生产合同回归（AndroidServices.Tests，主机夹具）：HostApi / 服务状态 / HostUi / 手柄设置小程序 / 键盘的生产源码。
# 只证主机侧合同，不证 guest / GPU / 真机；构建产物在临时目录或调用方给的共用目录，不写 checkout。
# 可选 $1：共用的构建产物目录。拆线程主机套件传入 run_shutdown_thread.sh 已编好 S2A.Services / Ryujinx 的那个目录，
# 依赖不再重编、只编本测试工程；不给就在临时目录单独构建（开发时单跑）。
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
if [ $# -ge 1 ]; then
    art=$1
else
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    art=$tmp/artifacts
fi
dotnet=${DOTNET:-dotnet}
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE=1 DOTNET_NOLOGO=1
"$dotnet" build "$here/AndroidServices.Tests.csproj" -c Release --disable-build-servers \
    -p:ArtifactsPath="$art" -p:NuGetAudit=false --verbosity quiet
"$dotnet" "$art/bin/AndroidServices.Tests/release/AndroidServices.Tests.dll"
