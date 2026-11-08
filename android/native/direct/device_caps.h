// 设备侧真实能力/limits（Vulkan physical device 实测值）→ 紧凑 JSON。
// 编译请求里的 enabled profile 必须由此合成（编译器侧只提供 layout/ABI 哈希），不能填默认值。
#pragma once
#include <stddef.h>
#include "vk_device.h"

#ifdef __cplusplus
extern "C" {
#endif
// 返回 0 成功，写入 out（≤ cap）并以 0 结尾；*len 为实际字节数（不含结尾 0）。
int s2a_vk_device_caps_json(const struct s2a_vk_device *device, char *out, size_t cap, size_t *len);
#ifdef __cplusplus
}
#endif
