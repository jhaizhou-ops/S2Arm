#!/bin/bash
# 门禁覆盖：tests/vulkan_reserved_bindings/* compat/tree/src/Ryujinx.Graphics.Vulkan/Constants.cs compat/tree/src/Ryujinx.Graphics.Vulkan/DescriptorSetUpdater.cs compat/tree/src/Ryujinx.Graphics.Gpu/Shader/GpuAccessorBase.cs compat/tree/src/Ryujinx.Graphics.Shader/ResourceReservationCounts.cs compat/tree/src/Ryujinx.Graphics.Shader/Translation/ResourceReservations.cs
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v dotnet >/dev/null 2>&1 || ! dotnet --list-sdks | grep -q '^10\.'; then
    echo "缺少 .NET 10 SDK；未执行 Vulkan 保留绑定容量回归（不自动下载）" >&2
    exit 2
fi
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
P=tests/vulkan_reserved_bindings/ReservedBindings.csproj
dotnet restore "$P" --configfile tests/vulkan_reserved_bindings/NuGet.Config --artifacts-path "$T" -p:NuGetAudit=false
dotnet run --project "$P" --no-restore --artifacts-path "$T"
