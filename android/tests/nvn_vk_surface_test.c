#include <stdio.h>
#include "nvn_vk_surface.h"
int main(void) {
    VkSurfaceFormatKHR f1[] = {{VK_FORMAT_B8G8R8A8_UNORM, VK_COLOR_SPACE_SRGB_NONLINEAR_KHR},
                               {VK_FORMAT_R8G8B8A8_SRGB, VK_COLOR_SPACE_SRGB_NONLINEAR_KHR}};
    VkSurfaceFormatKHR a = nvn_vk_pick_surface_format(f1, 2, VK_FORMAT_R8G8B8A8_SRGB, VK_COLOR_SPACE_SRGB_NONLINEAR_KHR);
    VkSurfaceFormatKHR b = nvn_vk_pick_surface_format(f1, 2, VK_FORMAT_R16G16B16A16_SFLOAT, VK_COLOR_SPACE_SRGB_NONLINEAR_KHR);
    VkSurfaceFormatKHR e = nvn_vk_pick_surface_format(NULL, 0, VK_FORMAT_R8G8B8A8_SRGB, VK_COLOR_SPACE_SRGB_NONLINEAR_KHR);
    VkPresentModeKHR m1[] = {VK_PRESENT_MODE_IMMEDIATE_KHR, VK_PRESENT_MODE_FIFO_KHR};
    VkPresentModeKHR p1 = nvn_vk_pick_present_mode(m1, 2, VK_PRESENT_MODE_MAILBOX_KHR);
    VkPresentModeKHR p2 = nvn_vk_pick_present_mode(m1, 2, VK_PRESENT_MODE_IMMEDIATE_KHR);
    int ok = a.format == VK_FORMAT_R8G8B8A8_SRGB && b.format == VK_FORMAT_B8G8R8A8_UNORM &&
             e.format == VK_FORMAT_UNDEFINED && p1 == VK_PRESENT_MODE_FIFO_KHR && p2 == VK_PRESENT_MODE_IMMEDIATE_KHR;
    printf("preferred=%d fallback=%d empty=%d fifo=%d immediate=%d\n", (int)a.format, (int)b.format, (int)e.format, (int)p1, (int)p2);
    printf("nvn-vk-surface: %s\n", ok ? "ok" : "FAIL");
    return ok ? 0 : 1;
}
