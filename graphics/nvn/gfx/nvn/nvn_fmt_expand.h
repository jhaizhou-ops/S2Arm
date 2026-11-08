// 上传时展开（缺口族 30）：目标格式由 nvn_fmt_info.expand 给出，Metal / Vulkan 共用同一份像素规则。
#pragma once
#include <stddef.h>
#include <stdint.h>

// 格式 f 需要上传展开时返回 1，并给出目标 NVN 格式与目标每像素字节数；否则 0
int nvn_fmt_expand_target(uint32_t f, uint32_t *target, int *bytes_per_pixel);

// 把 w×h 的源像素（每行 pitch 字节，格式 f）展开到目标格式（每行 dpitch 字节）。0 成功，-1 不展开
int nvn_fmt_expand_upload(uint32_t f, const uint8_t *src, size_t pitch, uint32_t w, uint32_t h,
                          uint8_t *dst, size_t dpitch);
