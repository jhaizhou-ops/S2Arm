// 直连 GPU 身份行：READY 的 admission 会从原生 host log 里找 generic 的
// `PrintGpuInformation: <renderer> (Vulkan v<api>, Driver: <driver> <version>)`。
// 直连后端也必须给出同一语义的真实设备身份，不能把这一行留给 generic 路径。
#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// 返回 0 并写以 0 结尾的行；参数缺失或 cap 不足返回 -1。
// line 不含 "[s2a] " 前缀，由调用方按 host log 通道加上。
int s2a_vk_identity_line(const char *device_name, uint32_t api_version,
                         const char *driver_name, const char *driver_info,
                         char *out, size_t cap);

// VkPhysicalDeviceProperties.vendorID → 稳定的厂商标签（只做 ID 映射，不猜型号）。
// 9000 的 gpu_contains 是 "ARM v1.r32p1"：驱动名本身报 "Mali-G710 MC10"，
// 必须用 vendorID 得 "ARM" 才能与 generic 的 GpuDriver 对齐。
const char *s2a_vk_vendor_name(uint32_t vendor_id);

#ifdef __cplusplus
}
#endif
