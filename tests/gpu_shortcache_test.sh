#!/bin/bash
# 门禁覆盖：compat/tree/src/Ryujinx.Graphics.Gpu/Image/AutoDeleteCache.cs compat/tree/src/Ryujinx.Graphics.Gpu/Ryujinx.Graphics.Gpu.csproj tests/gpu_shortcache/*
# 贴图短缓存重复描述符单测（tests/gpu_shortcache/Program.cs）：同一 TextureDescriptor 两次 AddShortCache（另一张纹理 / 同一纹理），
#   修前 _shortCacheLookup.Add 抛 ArgumentException（#1364 歧路旅人 II 选人画面整会话失败），修后不抛、只留一个条目、引用计数不漂。
#   全部用真 GpuContext / PhysicalMemory / Texture / AutoDeleteCache，渲染器是桩。约 60 秒：bash tests/gpu_shortcache_test.sh
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); LOG=$T/run.log
MSBUILDDISABLENODEREUSE=1 timeout 600 dotnet run -c Release --project "$H/tests/gpu_shortcache/GpuShortCacheTest.csproj" --artifacts-path "$T/art" > "$LOG" 2>&1; rc=$?
if [ $rc = 0 ]; then grep -E '^[✓✗] |^gpu_shortcache：' "$LOG"; else echo "🔴 gpu_shortcache 退出 ${rc}："; tail -30 "$LOG"; fi
rm -rf "$T"; exit $rc
