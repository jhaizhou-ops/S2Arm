#!/bin/bash
# NativeAOT 堆快照集成单测（tests/aot_heap/verify.py：离线发布真 NativeAOT 夹具，经 LLDB 跑 tools/aot_heap.py 取快照、tools/aot_heap_summary.py 汇总；本机约 10 秒）
# 11-01 接线：扫描分母按 tests 目录后查出原先没有门禁调它。要已装的 .NET 10 SDK、NativeAOT 10.0.12 NuGet 包与 LLDB（不启用包源、不联网）。
#   verify.py 把证据写在 build/aot-heap-test-*；通过后删本次那份，红了留着当现场。
# 门禁覆盖：tests/aot_heap/* tools/aot_heap.py tools/aot_heap_summary.py
set -u; H=$(cd "$(dirname "$0")/.." && pwd)
DN=${DOTNET:-$HOME/.dotnet/dotnet}; [ -x "$DN" ] || DN=$(command -v dotnet)
o=$(python3 "$H/tests/aot_heap/verify.py" --dotnet "$DN" --nuget-packages "${NUGET_PACKAGES:-$HOME/.nuget/packages}" 2>&1); r=$?
echo "$o" | tail -5
ev=$(sed -n 's/.*Evidence: \(.*\)$/\1/p' <<< "$o" | tail -1)
if [ $r = 0 ]; then case "$ev" in "$H"/build/aot-heap-test-*) rm -rf "$ev" ;; esac; fi
exit $r
