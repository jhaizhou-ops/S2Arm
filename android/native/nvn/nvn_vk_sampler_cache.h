// 直连 Vulkan 后端的采样器缓存：NVN 采样器参数相同就复用同一个 VkSampler。
#pragma once
#include <stddef.h>
#include <vulkan/vulkan.h>
#include "nvn_obj.h"
#include "vk_device.h"

#ifdef __cplusplus
extern "C" {
#endif
struct nvn_vk_sampler_slot { samp_par p; VkSampler s; int valid; int cube_view; };
struct nvn_vk_sampler_cache {
    struct s2a_vk_device *d;
    struct nvn_vk_sampler_slot *slots;   // 可增长：缓存容量不是合法资源上限（审计 A1）
    int cap, n;
    uint32_t created, reused;
    // 哈希索引：值 = slots 下标 + 1（0 = 空）。判据仍是 (cube_view, samp_par 逐字节相同)，
    // 索引只把命中从 O(n) 变成 O(1)。分配失败时退回线性扫描（结果相同，只是慢）并打一行。
    int32_t *tab;
    int tab_cap;
};
void nvn_vk_sampler_cache_init(struct nvn_vk_sampler_cache *c, struct s2a_vk_device *d);
void nvn_vk_sampler_cache_destroy(struct nvn_vk_sampler_cache *c);
// 相同参数复用；未知枚举返回 VK_NULL_HANDLE 并写 why（不静默降级）。
VkSampler nvn_vk_sampler_cache_get(struct nvn_vk_sampler_cache *c, const samp_par *p, char *why, size_t why_size);
// 采样 CUBE/CUBE_ARRAY 视图时 Vulkan 要求 addressMode U/V/W 都是 CLAMP_TO_EDGE（NVN 的 wrap 在立方体
// 采样里没有别的合法映射）。cube_view=1 时按该要求建一个独立变体，缓存键包含这个标志。
VkSampler nvn_vk_sampler_cache_get_for_view(struct nvn_vk_sampler_cache *c, const samp_par *p, int cube_view,
                                           char *why, size_t why_size);
#ifdef __cplusplus
}
#endif
