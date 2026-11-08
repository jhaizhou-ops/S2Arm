#include "nvn_vk_surface.h"

VkSurfaceFormatKHR nvn_vk_pick_surface_format(const VkSurfaceFormatKHR *formats, uint32_t count,
                                              VkFormat preferred, VkColorSpaceKHR preferred_space) {
    if (!formats || count == 0) return (VkSurfaceFormatKHR){VK_FORMAT_UNDEFINED, preferred_space};
    for (uint32_t i = 0; i < count; i++)
        if (formats[i].format == preferred && formats[i].colorSpace == preferred_space) return formats[i];
    // 游戏 RT 是 UNORM，present 的 blit 在 UNORM→SRGB 目标上会按线性→sRGB 再编码一次，
    // 把已经显示编码的内容抬亮（标题/过场发白）。优先 UNORM swapchain（与 Ryujinx 通用模式一致），
    // 让合成器按 SRGB_NONLINEAR 解释同一批字节；只有 surface 完全不提供 UNORM 时才退回 SRGB。
    for (uint32_t i = 0; i < count; i++)
        if (formats[i].colorSpace == preferred_space &&
            (formats[i].format == VK_FORMAT_R8G8B8A8_UNORM || formats[i].format == VK_FORMAT_B8G8R8A8_UNORM))
            return formats[i];
    for (uint32_t i = 0; i < count; i++)
        if (formats[i].colorSpace == preferred_space &&
            (formats[i].format == VK_FORMAT_R8G8B8A8_SRGB || formats[i].format == VK_FORMAT_B8G8R8A8_SRGB))
            return formats[i];
    return formats[0];
}

VkPresentModeKHR nvn_vk_pick_present_mode(const VkPresentModeKHR *modes, uint32_t count,
                                          VkPresentModeKHR preferred) {
    if (modes) for (uint32_t i = 0; i < count; i++) if (modes[i] == preferred) return preferred;
    if (modes) for (uint32_t i = 0; i < count; i++) if (modes[i] == VK_PRESENT_MODE_FIFO_KHR) return VK_PRESENT_MODE_FIFO_KHR;
    return VK_PRESENT_MODE_FIFO_KHR;
}
