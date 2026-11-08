#!/bin/bash
# 门禁覆盖：compat/tree/src/Ryujinx.Graphics.Gpu/Memory/BufferCache.cs compat/tree/src/Ryujinx.Graphics.Gpu/Ryujinx.Graphics.Gpu.csproj tests/gpu_bufrecreate/*
# 缓冲表合并窗口一致性单测（tests/gpu_bufrecreate/Program.cs）：CreateBufferAligned 合并分支
#   先 RemoveRange 旧缓冲、新缓冲入表之前 RecreateMultiRangeBuffers 嵌套另建同址缓冲，外层再 Add
#   把重叠缓冲塞进「互不重叠」表（BotW 8E/9000/9400 generic READY+~70s NRE），
#   修前表出现重叠项（断言红），修后表始终一致；「已映射但无缓冲」的查找走显式异常。
#   全部用真 GpuContext / PhysicalMemory / MemoryManager / BufferCache / CPU 跟踪内存，渲染器是桩。约 60 秒：bash tests/gpu_bufrecreate_test.sh
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); LOG=$T/run.log
MSBUILDDISABLENODEREUSE=1 timeout 600 dotnet run -c Release --project "$H/tests/gpu_bufrecreate/GpuBufferRecreateTest.csproj" --artifacts-path "$T/art" > "$LOG" 2>&1; rc=$?
if [ $rc = 0 ]; then grep -E '^[✓✗] |^gpu_bufrecreate：' "$LOG"; else echo "🔴 gpu_bufrecreate 退出 ${rc}："; tail -30 "$LOG"; fi
rm -rf "$T"; exit $rc
