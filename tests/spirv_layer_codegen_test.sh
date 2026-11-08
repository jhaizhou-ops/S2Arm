#!/bin/bash
# Real guest decoder/codegen and SPIR-V Tools validation; no Vulkan device is used.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
if [ -n "${S2A_LAYER_TEST_OUT:-}" ]; then
  out=$S2A_LAYER_TEST_OUT
  test ! -e "$out"
else
  parent=${S2A_CONTRIB_TMP:-"$root/build"}
  mkdir -p "$parent"
  out=$(mktemp -d "$parent/s2a-spirv-layer.XXXXXXXX")
  trap 'rm -rf "$out"' EXIT
fi
mkdir -p "$out/tmp" "$out/modules"
export TMPDIR="$out/tmp" MSBUILDDISABLENODEREUSE=1
printf '<configuration><packageSources><clear /></packageSources></configuration>\n' > "$out/NuGet.Config"
dotnet run -c Release --project "$root/graphics/vulkan/runtime/varying-tests/Varying.Tests.csproj" --artifacts-path "$out/art" -p:NuGetAudit=false -p:RestoreConfigFile="$out/NuGet.Config" -- "$out/modules" spirv-layer
for n in 1 2 3; do
  spirv-val --target-env vulkan1.2 "$out/modules/core$n.spv"
  spirv-val --target-env vulkan1.1 "$out/modules/ext$n.spv"
done
spirv-val --target-env vulkan1.2 "$out/modules/vtg-core.spv"
spirv-val --target-env vulkan1.1 "$out/modules/vtg-ext.spv"
spirv-val --target-env vulkan1.1 "$out/modules/nv.spv"
echo 'SPIR-V validation passed for core and extension layer/viewport modules'
