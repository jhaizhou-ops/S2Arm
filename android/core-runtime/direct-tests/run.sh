#!/usr/bin/env bash
# 安卓直连服务装配回归（Direct.Tests，主机夹具）：生产 direct service renderer 的生命周期 / 命令拒收、applet Exit 入队与缺状态拒收。
# 不需要 GPU、真机或游戏；构建产物在临时目录或调用方给的共用目录，不写 checkout。
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
"$dotnet" build "$here/Direct.Tests.csproj" -c Release --disable-build-servers \
    -p:ArtifactsPath="$art" -p:NuGetAudit=false --verbosity quiet
"$dotnet" "$art/bin/Direct.Tests/release/Direct.Tests.dll"
