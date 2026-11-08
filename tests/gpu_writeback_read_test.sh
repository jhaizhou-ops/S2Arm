#!/bin/bash
# 门禁覆盖：compat/tree/src/Ryujinx.Graphics.Gpu/Memory/PhysicalMemory.cs tests/gpu_writeback_read/*
# GPU 回写 / DMA 保留读取的读取次序（审计 #1534 P1-7 / P1-17）。
#   真 GpuContext / PhysicalMemory + 产品 GuestMemory / MemoryTracking + 桩渲染器：不跟踪回写区域有提供者时只经提供者取旧字节；
#   DMA 部分矩形保留读取先对目标发读跟踪（回写）再拷。约 1–3 分钟（首编 Ryujinx.Graphics.Gpu）：bash tests/gpu_writeback_read_test.sh
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d)
MSBUILDDISABLENODEREUSE=1 timeout 900 dotnet build "$H/tests/gpu_writeback_read/GpuWritebackReadTest.csproj" -c Release -o "$T/bin" -v quiet -nologo > "$T/build.log" 2>&1 || { tail -30 "$T/build.log"; rm -rf "$T"; exit 2; }
(cd "$T/bin" && timeout 120 dotnet GpuWritebackReadTest.dll); rc=$?
rm -rf "$T"; exit $rc
