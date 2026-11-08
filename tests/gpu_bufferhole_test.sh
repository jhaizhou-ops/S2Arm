#!/bin/bash
# 门禁覆盖：compat/tree/src/Ryujinx.Graphics.Gpu/Memory/BufferCache.cs compat/tree/src/Ryujinx.Graphics.Gpu/Ryujinx.Graphics.Gpu.csproj tests/gpu_bufferhole/*
# 计算存储缓冲带洞多段单测（tests/gpu_bufferhole/Program.cs）：GPU 虚址含未映射洞的多段缓冲提交绑定时
#   GetBuffer 对 PteUnmapped 子段 FindOverlap(ulong.MaxValue) 得空后解引用（BotW qbotw8e READY+68.3s 整会话崩），
#   修前 NRE，修后跳过洞段正常返回；全映射两段负对照修前修后都绿。
#   全部用真 GpuContext / PhysicalMemory / MemoryManager / BufferCache / CPU 跟踪内存，渲染器是桩。约 60 秒：bash tests/gpu_bufferhole_test.sh
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); LOG=$T/run.log
MSBUILDDISABLENODEREUSE=1 timeout 600 dotnet run -c Release --project "$H/tests/gpu_bufferhole/GpuBufferHoleTest.csproj" --artifacts-path "$T/art" > "$LOG" 2>&1; rc=$?
if [ $rc = 0 ]; then grep -E '^[✓✗] |^gpu_bufferhole：' "$LOG"; else echo "🔴 gpu_bufferhole 退出 ${rc}："; tail -30 "$LOG"; fi
rm -rf "$T"; exit $rc
