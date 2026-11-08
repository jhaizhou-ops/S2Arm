#pragma once
#include <vulkan/vulkan_core.h>
#include <limits.h>

// This initial VI adapter owns three logical images and guarantees one
// outstanding acquire. Host BufferQueue image count is independent.
#define S2A_VI_IMAGES 3
static inline VkResult s2a_vi_capabilities(const VkSurfaceCapabilitiesKHR *native, VkSurfaceCapabilitiesKHR *out) {
    if (!(native->supportedUsageFlags & VK_IMAGE_USAGE_TRANSFER_DST_BIT)) return VK_ERROR_FORMAT_NOT_SUPPORTED;
    *out = *native;
    out->minImageCount = out->maxImageCount = S2A_VI_IMAGES;
    out->currentExtent = (VkExtent2D){UINT32_MAX, UINT32_MAX};
    out->maxImageArrayLayers = 1;
    out->currentTransform = VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR;
    out->supportedTransforms = VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR;
    out->supportedCompositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
    out->supportedUsageFlags &= VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_SAMPLED_BIT |
        VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT;
    return VK_SUCCESS;
}
static inline int s2a_vi_fit(VkExtent2D src, VkExtent2D dst, VkRect2D *out) {
    if (!src.width || !src.height || !dst.width || !dst.height ||
        dst.width > INT_MAX || dst.height > INT_MAX) return 0;
    uint32_t w = dst.width, h = dst.height;
    if ((uint64_t)w * src.height > (uint64_t)h * src.width) w = (uint64_t)h * src.width / src.height;
    else h = (uint64_t)w * src.height / src.width;
    if (!w || !h) return 0;
    *out = (VkRect2D){{(int32_t)((dst.width - w) / 2), (int32_t)((dst.height - h) / 2)}, {w,h}};
    return 1;
}
static inline VkImageLayout s2a_vi_layout(VkImageLayout layout) {
    return layout == VK_IMAGE_LAYOUT_PRESENT_SRC_KHR ? VK_IMAGE_LAYOUT_GENERAL : layout;
}
