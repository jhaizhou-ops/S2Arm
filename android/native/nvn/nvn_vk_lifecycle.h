// 呈现/窗口生命周期的纯决策：不依赖 Vulkan、Android 或线程，生产路径与宿主回归共用同一份规则。
//
// 这些规则回答三件容易混在一起的事：
//   * 已挂载的窗口代际还能不能继续用（换代/撤销）、只是尺寸变了要不要原地重建（旋转）；
//   * 没有 surface 的 present 什么时候才允许解锁本帧纹理 pin（必须先有 GPU 完成证明）；
//   * 呈现退休有界预算：HOME/Stop/旋转都可能没有“下一帧”来等 present fence，不能无限等。
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// nvn_vk_window_action 的结果。
enum {
    NVK_WINDOW_REVOKED = -1,   // 租约已没有窗口 / 换代 / stopping：先拆交换链，再归还租约
    NVK_WINDOW_KEEP = 0,       // 同一代、同一尺寸：继续用当前交换链
    NVK_WINDOW_REBUILD = 1     // 同一代但窗口尺寸变化（旋转/分屏）：拆交换链后按同一窗口原地重建
};

// 比较“后端当前挂载的窗口身份”和“租约现在的状态”。
// attached=0 时调用方还没挂窗口，本函数返回 NVK_WINDOW_KEEP，由调用方走 take/attach。
// 尺寸取发布窗口坐标（present 的 Identity preTransform 契约），不是旋转前图像尺寸。
int nvn_vk_window_action(int attached, uint64_t attached_generation,
                         int32_t attached_width, int32_t attached_height,
                         int lease_has_window, uint64_t lease_generation, int lease_stopping,
                         int32_t lease_width, int32_t lease_height);

// 无 surface 的 present 收尾：只有帧队列给出“GPU 已完成”的证明（flush 返回 0）才允许
// 调 nvn_vk_first_draw_present_done 解锁纹理 pin。失败/未证明时保留 pin，不能借跳过上屏
// 把仍在 GPU 读取的资源标成可回收。
int nvn_vk_skip_present_unpin_allowed(int flush_rc);

// 单次 acquire 的有限超时：present 不能无界等图像，否则窗口撤销/后台时 UI 线程的
// surfaceDestroyed 会卡在 g_mu 上直到超时 abort。超时不是失败（没有 image 被取出）。
#define NVK_PRESENT_ACQUIRE_TIMEOUT_NS (100000000ull)

// 一次呈现退休（present fence signal）的有界预算。present 本身同步返回成功，但呈现退休证据
// 可能要到下一帧或 Stop 才有机会观察；HOME/旋转/退出都必须在这个预算内收口。
// 必须小于外壳 surfaceDestroyed 的 1 s 期限：撤销路径要先拆交换链再 revoke，不能把 UI 拖过 ANR。
#define NVK_PRESENT_RETIRE_BUDGET_NS (500000000ll)

#ifdef __cplusplus
}
#endif
