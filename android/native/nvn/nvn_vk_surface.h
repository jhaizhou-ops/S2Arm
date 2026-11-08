// 新后端 present 的 surface 选择：从设备给出的格式/呈现模式里挑一个明确的组合（不猜、不硬编码设备）。
#pragma once
#include <vulkan/vulkan.h>

#ifdef __cplusplus
extern "C" {
#endif
VkSurfaceFormatKHR nvn_vk_pick_surface_format(const VkSurfaceFormatKHR *formats, uint32_t count,
                                              VkFormat preferred, VkColorSpaceKHR preferred_space);
// FIFO 由规范保证可用；找不到 preferred 时回 FIFO，再回第一个。
VkPresentModeKHR nvn_vk_pick_present_mode(const VkPresentModeKHR *modes, uint32_t count,
                                          VkPresentModeKHR preferred);
#ifdef __cplusplus
}
#endif
