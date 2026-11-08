#include "nvn_vk_lifecycle.h"

int nvn_vk_window_action(int attached, uint64_t attached_generation,
                         int32_t attached_width, int32_t attached_height,
                         int lease_has_window, uint64_t lease_generation, int lease_stopping,
                         int32_t lease_width, int32_t lease_height) {
    if (!attached) return NVK_WINDOW_KEEP;   // 调用方还没挂窗口：由 take/attach 路径处理
    // 租约撤销、进程停止、换代：旧交换链不能继续 present，必须先退休再归还租约。
    if (!lease_has_window || lease_stopping) return NVK_WINDOW_REVOKED;
    if (attached_generation != lease_generation) return NVK_WINDOW_REVOKED;
    // 没有有效发布尺寸时不能继续用旧 extent 猜；按撤销处理，等下一次合法 generation。
    if (lease_width <= 0 || lease_height <= 0) return NVK_WINDOW_REVOKED;
    // 同一代窗口尺寸变化＝旋转/分屏/resize：swapchain 的 extent 必须按新发布坐标重建。
    if (lease_width != attached_width || lease_height != attached_height) return NVK_WINDOW_REBUILD;
    return NVK_WINDOW_KEEP;
}

int nvn_vk_skip_present_unpin_allowed(int flush_rc) { return flush_rc == 0; }
