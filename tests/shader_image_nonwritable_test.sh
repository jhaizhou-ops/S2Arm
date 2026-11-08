#!/bin/bash
# 门禁覆盖：compat/tree/src/Ryujinx.Graphics.Shader/CodeGen/Spirv/Declarations.cs compat/tree/src/Ryujinx.Graphics.Shader/Translation/ResourceManager.cs tests/shader_image_nonwritable/*
# #1165：没被写过的存储图像 / 存储 texel buffer 带 NonWritable（安卓 Mali 顶点阶段直连门槛），写过 / 原子的不带
set -eu
H=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
project="$H/tests/shader_image_nonwritable/ShaderImageNonWritable.csproj"
dotnet restore "$project" --configfile "$H/tests/shader_image_nonwritable/NuGet.Config" -p:BaseIntermediateOutputPath="$T/obj/" >/dev/null
dotnet build "$project" --no-restore -o "$T/bin" -p:BaseIntermediateOutputPath="$T/obj/" >/dev/null
dotnet "$T/bin/ShaderImageNonWritable.dll"
