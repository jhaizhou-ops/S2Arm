// 宿主回归用的最小 Vulkan 头入口。
// 仓库内 graphics/nvn/third_party/vulkan-headers 只带 vulkan_core.h（NDK/设备侧由 SDK 提供 vulkan.h）；
// 宿主测试只用类型与枚举（不建 device、不调函数），这里把 core 头接上，避免改第三方目录。
// VK_USE_PLATFORM_ANDROID_KHR 时补 Android surface 的最小类型（头桩在本目录的 android/ 下）。
#pragma once
#include <vulkan/vulkan_core.h>

#ifdef VK_USE_PLATFORM_ANDROID_KHR
#ifndef S2A_HOSTVK_ANDROID_SURFACE
#define S2A_HOSTVK_ANDROID_SURFACE
typedef struct ANativeWindow ANativeWindow;
typedef struct VkAndroidSurfaceCreateInfoKHR {
    VkStructureType sType;
    const void *pNext;
    VkFlags flags;
    ANativeWindow *window;
} VkAndroidSurfaceCreateInfoKHR;
typedef VkResult (VKAPI_PTR *PFN_vkCreateAndroidSurfaceKHR)(
    VkInstance instance, const VkAndroidSurfaceCreateInfoKHR *pCreateInfo,
    const VkAllocationCallbacks *pAllocator, VkSurfaceKHR *pSurface);
#define VK_KHR_ANDROID_SURFACE_EXTENSION_NAME "VK_KHR_android_surface"
#endif
#endif
