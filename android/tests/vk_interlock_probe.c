// 设备能力探针：Adreno 730 是否支持 VK_EXT_fragment_shader_interlock（暗黑3 当前 fatal 的能力）。
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>
#include "vk_device.h"

int main(void) {
    struct s2a_vk_device d; char why[192] = "";
    if (s2a_vk_device_create(&d, why, sizeof why)) { printf("FAIL device: %s\n", why); return 1; }
    uint32_t n = 0;
    vkEnumerateDeviceExtensionProperties(d.physical, NULL, &n, NULL);
    VkExtensionProperties *ext = calloc(n, sizeof *ext);
    vkEnumerateDeviceExtensionProperties(d.physical, NULL, &n, ext);
    int have_ext = 0;
    for (uint32_t i = 0; i < n; i++) if (!strcmp(ext[i].extensionName, "VK_EXT_fragment_shader_interlock")) have_ext = 1;
    VkPhysicalDeviceFragmentShaderInterlockFeaturesEXT il = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FRAGMENT_SHADER_INTERLOCK_FEATURES_EXT };
    VkPhysicalDeviceFeatures2 f2 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2 };
    f2.pNext = &il;
    vkGetPhysicalDeviceFeatures2(d.physical, &f2);
    printf("interlock: ext=%d sample=%d pixel=%d\n", have_ext, il.fragmentShaderSampleInterlock, il.fragmentShaderPixelInterlock);
    printf("vk-interlock: %s\n", have_ext && il.fragmentShaderPixelInterlock ? "ok (supported)" : "unsupported");
    free(ext); s2a_vk_device_destroy(&d, 0);
    return 0;
}
