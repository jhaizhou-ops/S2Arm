// 反馈快照池的复用/淘汰判据（纯逻辑，宿主可测；生产实现见 nvn_vk_first_draw.c）。
// 维护方审 11-04 第 6 条：不能用全局周期计数代替“所属那一帧已完成”。
//   延迟上屏时帧 N 提交后退休更早的槽也会推进计数，帧 N 仍在 GPU 上却被判可复用：
//   复用 → 与上一帧片元读取竞争（WAR）；淘汰 → 释放 GPU 仍在用的图。
#pragma once
#include <stdint.h>

// 只有“所属帧已经拿到完成证明”（owner_frame <= retired_frame）的槽才可复用/淘汰。
// retired_frame 的来源：延迟槽退休取该槽 frame_id；同步 flush 等完 fence 后取当前帧号。
static inline int nvn_vk_snap_slot_reusable(int used, uint64_t owner_frame, uint64_t retired_frame) {
    return used && owner_frame <= retired_frame;
}
