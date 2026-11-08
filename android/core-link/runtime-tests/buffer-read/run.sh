#!/usr/bin/env bash
# Buffer 正常上传读取回归的门禁入口（README 三步串起来：dotnet build → 编 Mac VM 原生夹具 → run.py 逐用例）；只在 macOS 跑（夹具用 Mach VM），不联网、不往 checkout 写产物
set -euo pipefail
# 物理路径（pwd -P）：checkout 路径带符号链接（/tmp → /private/tmp）时，逻辑路径传给 --artifacts-path 会让项目引用落到不存在的产物目录，188 个 CS0234（#199）
here=$(cd "$(dirname "$0")" && pwd -P); root=$(cd "$here/../../../.." && pwd -P)
[ "$(uname -s)" = Darwin ] || { echo 'buffer-read：只在 macOS 跑（原生夹具用 Mach VM），本机跳过'; exit 0; }
dotnet_bin=${DOTNET:-$(command -v dotnet || true)}
[ -n "$dotnet_bin" ] || { echo '🔴 buffer-read: .NET 10 SDK required (set DOTNET or PATH)' >&2; exit 1; }
export DOTNET_PROCESSOR_COUNT=${DOTNET_PROCESSOR_COUNT:-2}
out=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/s2a-buffer-read.XXXXXX")" && pwd -P); trap 'rm -rf "$out"' EXIT
printf '%s\n' '<configuration><packageSources><clear /></packageSources></configuration>' > "$out/NuGet.Config"
"$dotnet_bin" build "$here/BufferRead.Tests.csproj" --configfile "$out/NuGet.Config" --artifacts-path "$out/build" -p:NuGetAudit=false -v:q
rc="$root/android/core-link/runtime-tests/readonly-copy"
clang -std=gnu11 -O2 -fPIC -dynamiclib -pthread -I"$root/runtime/include" "$rc/native_fixture.c" "$rc/mac_vm_adapter.c" \
    "$root/android/native/runtime/tracking/readonly_copy.c" "$root/graphics/track/track.c" -o "$out/libreadonly_fixture.dylib"
python3 "$here/run.py" --out "$out" --dotnet "$dotnet_bin"
echo 'buffer-read 期望 旧保护源路径 AV、恢复可读后转绿等全部用例过 → 真结果 通过'
