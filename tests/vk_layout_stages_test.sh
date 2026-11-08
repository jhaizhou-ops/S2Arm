#!/bin/bash
# 门禁覆盖：compat/tree/src/Ryujinx.Graphics.Gpu/Shader/ShaderInfoBuilder.cs compat/tree/src/Ryujinx.Graphics.Gpu/Ryujinx.Graphics.Gpu.csproj tests/vk_layout_stages/*
# 着色器描述符阶段位单测（tests/vk_layout_stages/Program.cs）：9000（Mali）没有 depth clip control、S2A 运行时状态开时，
#   翻译 VS→GS→FS，GS 的深度重映射读支持缓冲 (set 0 / binding 0)；断言 SPIR-V 实际用到的每个 (set, binding) 在
#   ShaderInfoBuilder 产出的资源布局里都包含使用它的阶段。修前 GS 缺 Geometry 阶段位判红；另核支持缓冲覆盖 VtgStages。
#   不碰 Vulkan 设备。约 60 秒：bash tests/vk_layout_stages_test.sh
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); LOG=$T/run.log
MSBUILDDISABLENODEREUSE=1 timeout 600 dotnet run -c Release --project "$H/tests/vk_layout_stages/VkLayoutStagesTest.csproj" --artifacts-path "$T/art" > "$LOG" 2>&1; rc=$?
if [ $rc = 0 ]; then grep -E '^[✓✗] |^vk_layout_stages：' "$LOG"; else echo "🔴 vk_layout_stages 退出 ${rc}："; tail -30 "$LOG"; fi
rm -rf "$T"; exit $rc
