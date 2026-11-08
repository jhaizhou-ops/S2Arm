// 宿主回归：呈现/窗口生命周期的纯决策（生产用的 nvn_vk_lifecycle.c）。
//
// 覆盖：
//   * 无 surface：没有 GPU 完成证明（flush != 0）时不允许解锁 pin；
//   * generation 变化：窗口换代/租约撤销/stopping 都必须先拆交换链、归还租约，不能继续 present；
//   * 旋转/resize：同一代窗口尺寸变化 → 原地重建；同尺寸 → 保留；
//   * 无效发布尺寸：不拿旧 extent 猜。
#include <stdio.h>
#include <string.h>

#include "nvn_vk_lifecycle.h"

static int g_failures;
#define CHECK(cond, ...) do { if (!(cond)) { printf("FAIL: "); printf(__VA_ARGS__); printf("\n"); g_failures++; } } while (0)

int main(void) {
    // 无 surface 的 present：只有 flush 给出完成证明才允许 unpin。
    CHECK(nvn_vk_skip_present_unpin_allowed(0) == 1, "flush=0 allows unpin");
    CHECK(nvn_vk_skip_present_unpin_allowed(-1) == 0, "flush=-1 keeps pins");
    CHECK(nvn_vk_skip_present_unpin_allowed(1) == 0, "flush=1 (not complete) keeps pins");

    // 窗口换代 / 撤销。
    CHECK(nvn_vk_window_action(1, 7, 1920, 1080, 0, 7, 0, 1920, 1080) == NVK_WINDOW_REVOKED,
          "lease window gone revokes");
    CHECK(nvn_vk_window_action(1, 7, 1920, 1080, 1, 8, 0, 1920, 1080) == NVK_WINDOW_REVOKED,
          "new lease generation revokes old swapchain");
    CHECK(nvn_vk_window_action(1, 7, 1920, 1080, 1, 7, 1, 1920, 1080) == NVK_WINDOW_REVOKED,
          "stopping lease revokes");
    CHECK(nvn_vk_window_action(1, 7, 1920, 1080, 1, 7, 0, 0, 1080) == NVK_WINDOW_REVOKED,
          "zero published width revokes instead of guessing");
    CHECK(nvn_vk_window_action(1, 7, 1920, 1080, 1, 7, 0, 1920, -1) == NVK_WINDOW_REVOKED,
          "negative published height revokes");

    // 同一代窗口：尺寸不变保留，尺寸变化原地重建（旋转/resize/分屏）。
    CHECK(nvn_vk_window_action(1, 7, 1920, 1080, 1, 7, 0, 1920, 1080) == NVK_WINDOW_KEEP,
          "same generation and size keeps");
    CHECK(nvn_vk_window_action(1, 7, 1920, 1080, 1, 7, 0, 1080, 1920) == NVK_WINDOW_REBUILD,
          "rotation rebuilds the swapchain");
    CHECK(nvn_vk_window_action(1, 7, 2560, 1440, 1, 7, 0, 1920, 1080) == NVK_WINDOW_REBUILD,
          "window resize rebuilds the swapchain");

    // 还没挂窗口：由调用方的 take/attach 路径处理，不在这个决策里“撤销”。
    CHECK(nvn_vk_window_action(0, 0, 0, 0, 1, 9, 0, 1920, 1080) == NVK_WINDOW_KEEP,
          "unattached window keeps (caller takes it)");

    if (g_failures) {
        printf("nvn_vk_lifecycle test: %d failure(s)\n", g_failures);
        return 1;
    }
    printf("nvn_vk_lifecycle test: ok (skip-present proof, generation revoke, rotation rebuild)\n");
    return 0;
}
