#!/bin/bash
# 门禁只看：graphics/gate.sh
# gfx 钩子按依赖分组单测（GFX_GATE_PLAN=1 只打印各组跑 / 不跑，不跑任何测试，约 1 秒）：bash tests/gfx_gate_group_test.sh
# 期望按 graphics/gate.sh 各组前缀与各 .csproj 的工程引用手写（不跑被测实现推期望）：
#   只改 runtime/src/crash.c → 只有上屏驻留集成（它把 runtime/src/*.c 全编进替身宿主）；改渲染器 → 渲染器 / 计数回调 / Metal 3 归档 / 直连曲面（组 direct_link）+ 上屏驻留；
#   改 Ryujinx.Graphics.Gpu → 引到 Gpu 的 .NET 组（写跟踪 .NET、共享合同、Vulkan 诊断经 S2A.Services、纹理 DMA、shbake），计数回调只引 GAL / Memory 不跑；
#   帧节奏 frame_pacing（11-01 审计 P1-39）：FramePacingTest → S2A.Gfx（graphics/loop）→ NxGal（GAL / Memory）+ Ryujinx.HLE（引 Gpu / GAL）→ 改 Gpu / HLE / GAL / graphics/loop / tests/frame_pacing 都跑；
#   图形会话 session（11-01 接线）：Session.csproj 与 CntDead.csproj 同样只引 NxGal.csproj，与计数回调 cntdead 同进同出；
#   改钩子自己 / 改动集空 → 新分组全跑；闭包算不出（python3 失败）→ .NET 组全跑（宁多勿漏）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); cd "$H"; bad=0; n=0
# awk 固定 C locale：BSD awk 在 en_US.UTF-8 下把「不跑」也当成「跑」（本机 11-03 实测），会让 14 组全判不符
plan() { GATE_CHANGED="$1" GFX_GATE_PLAN=1 bash graphics/gate.sh | LC_ALL=C awk '$2 == "跑" { printf "%s%s", s, $1; s = " " }'; }
ck() { local got; n=$((n + 1)); got=$(plan "$1"); if [ "$got" = "$2" ]; then echo "通 改 [${1}] → ${got}"; else echo "不通 改 [${1}]：期望 [${2}] → 真结果 [${got}]"; bad=1; fi; }
NEW="track_c track_net shared_gpu_contract vulkan_diag vvl texture_dma_read metal cntdead session m3pack direct_link shbake_net frame_pacing"
ck "runtime/src/crash.c" "present_residency"
ck "graphics/metal/gal_present.m" "metal cntdead session m3pack direct_link present_residency"
ck "graphics/track/xxx" "track_net present_residency"
ck "graphics/track/track.c" "track_c track_net texture_dma_read present_residency"
ck "compat/tree/src/Ryujinx.Graphics.Gpu/xxx" "track_net shared_gpu_contract vulkan_diag vvl texture_dma_read shbake_net frame_pacing"
ck "compat/tree/src/Ryujinx.HLE/HOS/Services/Foo.cs" "vulkan_diag frame_pacing"
ck "graphics/tools/shbake/tests/t_vvl_clamp.sh" "vvl m3pack shbake_net pso shdist"
ck "compat/tree/src/Ryujinx.Graphics.GAL/IRenderer.cs" "track_net shared_gpu_contract vulkan_diag vvl texture_dma_read cntdead session shbake_net frame_pacing"
ck "tests/frame_pacing/Program.cs" "frame_pacing"
ck "graphics/loop/RenderLoop.cs" "frame_pacing"
ck "graphics/tools/shbake/pso_gen.py" "m3pack shbake_net pso shdist"
ck "docs/x.md runtime/src/hud.c" "present_residency fps_limit"
ck "graphics/gate.sh" "$NEW vk present_residency fps_limit present_settings"
ck "" "$NEW nvn red nvn_tex pso dsh gl vk present_residency fps_limit present_settings shdist dmsh_giant"
# 闭包算不出时 .NET 组照跑：PATH 前放一个必失败的 python3
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; printf '#!/bin/sh\nexit 1\n' > "$T/python3"; chmod +x "$T/python3"
n=$((n + 1)); got=$(PATH="$T:$PATH" GATE_CHANGED="runtime/src/crash.c" GFX_GATE_PLAN=1 bash graphics/gate.sh | LC_ALL=C awk '$2 == "跑" { printf "%s%s", s, $1; s = " " }')
want="track_net shared_gpu_contract vulkan_diag vvl texture_dma_read cntdead session shbake_net frame_pacing present_residency"
if [ "$got" = "$want" ]; then echo "通 闭包算不出 → .NET 组全跑：${got}"; else echo "不通 闭包算不出：期望 [${want}] → 真结果 [${got}]"; bad=1; fi
echo "期望 ${n} 组改动集的分组计划全对 → 真结果 $([ $bad = 0 ] && echo "${n} 组全对 ✓" || echo "有不符 ✗")"
[ $bad = 0 ]
