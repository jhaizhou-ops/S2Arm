#!/bin/bash
# 门禁覆盖：compat/tree/src/Ryujinx.Graphics.Shader/Translation/ResourceManager.cs compat/tree/src/Ryujinx.Graphics.Shader/Translation/Transforms/TexturePass.cs tests/shader_txq/*
set -eu
H=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
project="$H/tests/shader_txq/ShaderTxqTest.csproj"
dotnet restore "$project" --configfile "$H/tests/shader_txq/NuGet.Config" -p:BaseIntermediateOutputPath="$T/obj/" >/dev/null
dotnet build "$project" --no-restore -o "$T/bin" -p:BaseIntermediateOutputPath="$T/obj/" >/dev/null
dotnet "$T/bin/ShaderTxqTest.dll"
