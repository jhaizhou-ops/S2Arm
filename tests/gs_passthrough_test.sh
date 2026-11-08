#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 门禁只看：translator/dmsh_xlate/* compat/tree/src/Ryujinx.Graphics.Shader/* graphics/tools/direct/tests/t_gs_passthrough.py
# 直通几何快路的翻译判定（graphics/tools/direct/tests/t_gs_passthrough.py；要 Homebrew 的 spirv-cross）：bash tests/gs_passthrough_test.sh
set -eu
R=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/gs_passthrough.XXXXXX")
trap 'rm -rf "$T"' EXIT
DN=${DOTNET:-dotnet}
command -v spirv-cross > /dev/null || { echo "直通几何快路单测：没有命令行 spirv-cross（Homebrew）→ 红"; exit 1; }
# Tests use restored packages only; an empty local feed prevents network access.
mkdir "$T/feed"
"$DN" restore "$R/translator/dmsh_xlate/dmsh_xlate.csproj" --artifacts-path "$T/artifacts" --source "$T/feed" -p:NuGetAudit=false > "$T/build.log" 2>&1 || { cat "$T/build.log"; exit 1; }
"$DN" build "$R/translator/dmsh_xlate/dmsh_xlate.csproj" -c Release --no-restore --artifacts-path "$T/artifacts" -o "$T/bin" -p:UseSharedCompilation=false >> "$T/build.log" 2>&1 || { cat "$T/build.log"; exit 1; }
DOTNET="$DN" "${S2A_PY:-python3}" "$R/graphics/tools/direct/tests/t_gs_passthrough.py" "$T/bin/dmsh_xlate.dll"
