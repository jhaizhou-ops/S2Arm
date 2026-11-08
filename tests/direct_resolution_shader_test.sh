#!/bin/bash
# Production helper IR arithmetic only; never initializes a GPU or a window.
# 门禁覆盖：compat/tree/src/Ryujinx.Graphics.Shader/SupportBuffer.cs compat/tree/src/Ryujinx.Graphics.Shader/Translation/HelperFunctionManager.cs compat/tree/src/Ryujinx.Graphics.Shader/Translation/Transforms/TexturePass.cs tests/direct_resolution_shader/*
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
dotnet build "$ROOT/tests/direct_resolution_shader/DirectResolutionShaderTest.csproj" -c Release -p:NuGetAudit=false -m:2 -v minimal "$@"
dotnet "$ROOT/tests/direct_resolution_shader/bin/Release/net10.0/DirectResolutionShaderTest.dll"
