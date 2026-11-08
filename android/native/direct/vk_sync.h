// C4：单队列 fence 完成证据与 batch 退休。present fence/WSI 退休共用这一入口；
// CPU 帧计时或 QueuePresent 返回不等于 scanout 完成。
#pragma once
#include "vk_device.h"

#ifdef __cplusplus
extern "C" {
#endif

struct s2a_vk_completion {
    VkFence fence;
    uint64_t batch;
    int pending;
};

// 提交并绑定 fence；同一 completion 未退休前不得复用。
int s2a_vk_completion_submit(struct s2a_vk_device *device, VkCommandBuffer command,
                             struct s2a_vk_completion *completion, uint64_t batch);
// 0=已完成并退休；1=超时仍 pending；-1=错误。成功后 fence 被销毁、pending 清零。
int s2a_vk_completion_wait(struct s2a_vk_device *device, struct s2a_vk_completion *completion,
                           uint64_t timeout_ns);
void s2a_vk_completion_destroy(struct s2a_vk_device *device, struct s2a_vk_completion *completion);

#ifdef __cplusplus
}
#endif
