// C4：单消费者 batch/资源退休账本。提交线程只入队，唯一消费者等待 fence 并回调；
// present fence 也走同一入口（WSI 接上后由 present 路径入队）。
#pragma once
#include "vk_device.h"

#ifdef __cplusplus
extern "C" {
#endif

struct s2a_vk_track;
typedef void (*s2a_vk_track_retire_fn)(void *user, uint64_t batch);

int s2a_vk_track_create(struct s2a_vk_device *device, struct s2a_vk_track **out);
// 提交命令并登记 batch；track 取得 fence 所有权。
int s2a_vk_track_submit(struct s2a_vk_track *track, VkCommandBuffer command, uint64_t batch,
                        s2a_vk_track_retire_fn retire, void *user);
// 已提交的 present fence 入队；track 取得 fence 所有权。
int s2a_vk_track_present_fence(struct s2a_vk_track *track, VkFence fence, uint64_t batch,
                               s2a_vk_track_retire_fn retire, void *user);
// 等待队列清空；0=全部退休，1=超时仍有在途，-1=等待/驱动错误。
int s2a_vk_track_wait_all(struct s2a_vk_track *track, uint64_t timeout_ms);
// 队列必须已清空；否则返回 -1 且不销毁，调用方保留 device/资源。
int s2a_vk_track_destroy(struct s2a_vk_track *track);
// 统计：已提交/已退休/在途/失败。
void s2a_vk_track_stats(struct s2a_vk_track *track, uint64_t *submitted, uint64_t *retired,
                        uint64_t *pending, uint64_t *failed);

#ifdef __cplusplus
}
#endif
