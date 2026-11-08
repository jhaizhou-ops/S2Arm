// 设备能力：instance 是否启用了 VK_KHR_android_surface（新后端 present 的前置）。
#include <stdio.h>
#include "vk_device.h"
int main(void) {
    struct s2a_vk_device d; char why[192] = "";
    if (s2a_vk_device_create(&d, why, sizeof why)) { printf("FAIL device: %s\n", why); return 1; }
    printf("android_surface=%d swapchain=%d\n", d.has_android_surface, d.has_swapchain);
    printf("vk-surface: %s\n", d.has_android_surface ? "ok" : "unsupported");
    int ok = d.has_android_surface;
    s2a_vk_device_destroy(&d, 0);
    return ok ? 0 : 1;
}
