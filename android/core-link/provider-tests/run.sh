#!/usr/bin/env bash
# 原生 provider 归属单测的门禁入口：run.py 要求 --out 在 checkout 外、只用本地 NuGet 缓存；只在 macOS 跑（provider.c 按 dylib 编）
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
[ "$(uname -s)" = Darwin ] || { echo 'provider-tests：只在 macOS 跑，本机跳过'; exit 0; }
command -v dotnet > /dev/null || export PATH="$HOME/.dotnet:$PATH"
out=$(mktemp -d "${TMPDIR:-/tmp}/s2a-provider-owner.XXXXXX"); trap 'rm -rf "$out"' EXIT
python3 "$here/run.py" --out "$out"
