#pragma once
#include <vulkan/vulkan.h>
#include "spirv_storage.h"

// The scanner must run before the first Vulkan call with this vertex module.
static inline VkResult s2a_vk_create_checked_vertex(VkDevice device, int feature_enabled,
                                                     const VkShaderModuleCreateInfo *info,
                                                     VkShaderModule *module, int *rejected) {
    if (rejected) *rejected = 0;
    if (!info || !module) return VK_ERROR_INITIALIZATION_FAILED;
    if (!feature_enabled && s2a_spirv_storage_need(info->pCode, info->codeSize, 0) != 0) {
        if (rejected) *rejected = 1;
        return VK_ERROR_FEATURE_NOT_PRESENT;
    }
    return vkCreateShaderModule(device, info, NULL, module);
}
