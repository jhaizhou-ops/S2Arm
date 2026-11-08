// 直连 GPU 身份行。值全部由调用方从 VkPhysicalDeviceProperties / driverProperties 传入，
// 本文件不查设备、不写死型号：只做稳定格式与容量校验。
#include "vk_identity.h"

#include <stdio.h>

const char *s2a_vk_vendor_name(uint32_t vendor_id) {
    switch (vendor_id) {
        case 0x13B5: return "ARM";
        case 0x5143: return "Qualcomm";
        case 0x10DE: return "NVIDIA";
        case 0x8086: return "Intel";
        case 0x1002: return "AMD";
        case 0x1010: return "Imagination";
        case 0x106B: return "Apple";
        case 0x1414: return "Microsoft";
        default: return "Unknown";
    }
}

int s2a_vk_identity_line(const char *device_name, uint32_t api_version,
                         const char *driver_name, const char *driver_info,
                         char *out, size_t cap) {
    if (!device_name || !*device_name || !driver_name || !driver_info || !out || !cap) return -1;
    // Vulkan 版本编码：major 10 位、minor 10 位、patch 12 位（与 VK_VERSION_* 同义）。
    unsigned major = (api_version >> 22) & 0x3ffu;
    unsigned minor = (api_version >> 12) & 0x3ffu;
    unsigned patch = api_version & 0xfffu;
    int n = snprintf(out, cap, "PrintGpuInformation: %s (Vulkan v%u.%u.%u, Driver: %s %s)",
                     device_name, major, minor, patch, driver_name, driver_info);
    if (n < 0 || (size_t)n >= cap) {
        if (cap) out[0] = 0;
        return -1;
    }
    return 0;
}
