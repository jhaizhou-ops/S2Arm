// NVN 采样器参数 → Vulkan VkSamplerCreateInfo 的通用映射（新 Vulkan 后端用）。
#pragma once
#include <vulkan/vulkan.h>
#include "nvn_obj.h"

#ifdef __cplusplus
extern "C" {
#endif
// 返回值：0 成功；-1 参数非法/未知枚举（调用方明确报红，不静默降级）。
int nvn_vk_sampler_from(const samp_par *p, VkSamplerCreateInfo *ci);
#ifdef __cplusplus
}
#endif
