#!/bin/bash
# 双轨覆盖率 seen 记录单测（Ryujinx S2ASeen，10-24 画面·着色器线）：先用 shasum 独立核期望里的三个哈希常量，再编 tests/seen（S2A.SeenTest）并跑；产物在 <仓库根>/build/seen_test。退出 0 = 全过
set -u
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../../../.." && pwd); OUT=$ROOT/build/seen_test
for kv in abc:ba7816bf8f01cfea x:2d711642b726b044 y:a1fce4363854ff88; do
  [ "$(printf %s "${kv%%:*}" | shasum -a 256 | cut -c1-16)" = "${kv#*:}" ] || { echo "期望常量 ${kv} 与 shasum 不符 ✗"; exit 2; }
done
mkdir -p "$OUT"; rm -rf "$OUT/run"; mkdir -p "$OUT/run"
timeout 500 dotnet build "$HERE/seen/S2A.SeenTest.csproj" -c Release --artifacts-path "$OUT/art" -v quiet -nologo > "$OUT/build.log" 2>&1 || { tail -30 "$OUT/build.log"; echo "期望 编过 → 真结果 编译失败 ✗"; exit 2; }
B=$(find "$OUT/art/bin/S2A.SeenTest" -name S2A.SeenTest.dll | head -1)
[ -n "$B" ] || { echo "期望 有 S2A.SeenTest.dll → 真结果 没找到 ✗"; exit 2; }
timeout 60 dotnet "$B" "$OUT/run"
