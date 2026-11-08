// enabled profile 合成（native 侧胶水，仅 nvn_vk 后端编译）。
// 设备事实由 device_caps.c 产出；compiler 常量/哈希在 managed（s2a_direct_profile_json_v1）里算。
// 这里只做：生成 caps → 调 managed → 复制结果（有界）→ 取出 profileHash 供 selection/attempt 使用。
#pragma once
#include <stddef.h>
#include "vk_device.h"

#ifdef __cplusplus
extern "C" {
#endif
// 成功返回 0；out 以 0 结尾，*len 为 JSON 字节数（不含结尾 0），profile_hash 收 "sha256-"+64hex。
// 失败返回非 0 并写 ASCII 原因。不写磁盘、不读磁盘、不猜默认值。
int s2a_direct_build_profile(const struct s2a_vk_device *device, const char *translator_closure,
                             char *out, size_t cap, size_t *len, char profile_hash[72],
                             char *why, size_t why_size);
#ifdef __cplusplus
}
#endif
