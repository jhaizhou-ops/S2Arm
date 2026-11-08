// 反馈快照池复用/淘汰判据单测（宿主）：只有“所属帧已完成”的槽可复用/淘汰。
// 反例来自维护方审 11-04 第 6 条：延迟上屏时用全局周期计数，帧 N 仍在途就被判可复用/可淘汰。
#include "nvn_vk_snap_pool.h"
#include <stdio.h>

int main(void) {
    int checks = 0, fails = 0;
#define CK(c, msg) do { checks++; if (!(c)) { fails++; printf("✗ %s\n", msg); } } while (0)

    // 反例：提交 N（owner=5）→ 录 N+1（retired=4，N 还没完成）：不可复用、不可淘汰。
    CK(!nvn_vk_snap_slot_reusable(1, 5, 4), "在途帧 N 的槽不可复用（owner=5 > retired=4）");
    // 正例：N 的完成证明到手（retired=5）后才可以复用。
    CK(nvn_vk_snap_slot_reusable(1, 5, 5), "所属帧完成后可复用（owner=5 <= retired=5）");
    CK(nvn_vk_snap_slot_reusable(1, 4, 5), "更早的已完成槽可复用（owner=4 <= retired=5）");
    // 空槽永远不算“可复用”（调用方按 used 判）。
    CK(!nvn_vk_snap_slot_reusable(0, 1, 99), "未使用的槽不算可复用");
    // 初始状态：retired=0、owner 从 1 起，任何在途槽都不可复用。
    CK(!nvn_vk_snap_slot_reusable(1, 1, 0), "初始 retired=0 时在途槽不可复用");

    if (fails) { printf("✗ t_nvn_vk_snap_pool：%d 处不符\n", fails); return 1; }
    printf("✓ t_nvn_vk_snap_pool：%d 项全过（在途帧槽不可复用/淘汰，完成证明后才可复用）\n", checks);
    return 0;
}
