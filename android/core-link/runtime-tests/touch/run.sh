#!/usr/bin/env bash
# 安卓触屏与 Gesture 机制回归（Touch.Tests，主机夹具）：生产 TouchHidState / TouchGestureState 加真实 Ryujinx
# GestureDevice、RingLifo、AtomicStorage。不需要 GPU、真机或游戏；构建产物在临时目录或调用方给的共用目录，不写 checkout。
# 引用 Ryujinx.HLE，要 Ryujinx.LibHac 预发布包：用 android/cs/nuget.config（仓库内 compat/packages 源）还原。
# 可选 $1：共用的构建产物目录。拆线程主机套件传入 run_shutdown_thread.sh 已编好 S2A.Services / Ryujinx 的那个目录，
# 依赖不再重编、只编本测试工程；不给就在临时目录单独构建（开发时单跑）。
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
if [ $# -ge 1 ]; then
    art=$1
else
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    art=$tmp/artifacts
fi
dotnet=${DOTNET:-dotnet}
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE=1 DOTNET_NOLOGO=1
"$dotnet" restore "$here/Touch.Tests.csproj" --configfile "$here/../../../cs/nuget.config" \
    -p:ArtifactsPath="$art" -p:NuGetAudit=false --verbosity quiet
"$dotnet" build "$here/Touch.Tests.csproj" -c Release --no-restore --disable-build-servers \
    -p:ArtifactsPath="$art" --verbosity quiet
# AssemblyName 是 Ryujinx.Tests（拿 Ryujinx.HLE 的 InternalsVisibleTo）。
"$dotnet" "$art/bin/Touch.Tests/release/Ryujinx.Tests.dll"
