// NVN 纹理格式 → Vulkan 格式的通用映射（新 Vulkan 后端用；不写死游戏）。
// 未知格式返回 VK_FORMAT_UNDEFINED，由调用方明确报红，不猜。
#pragma once
#include <stddef.h>
#include <stdint.h>
#include <vulkan/vulkan.h>

#ifdef __cplusplus
extern "C" {
#endif
int nvn_vk_format_is_depth(VkFormat f);
// 压缩块格式（BC/ASTC/ETC2）：视图格式覆盖不适用于它们。
int nvn_vk_format_is_compressed(VkFormat f);
// 压缩块格式的图像总字节数：按该格式自己的块宽高向上取整（ASTC 4x4…12x12、BC 4x4）。
// 未压缩格式或未知格式返回 0，由调用方按 bpp 处理或明确报红。
uint64_t nvn_vk_format_compressed_image_bytes(uint32_t nvn_format, uint32_t w, uint32_t h);
int nvn_vk_format_has_stencil(VkFormat f);
VkFormat nvn_vk_format(uint32_t nvn_format);
VkFormat nvn_vk_tex_format(uint32_t nvn_format);   // 贴图专用：需要上传展开时返回展开目标格式
// CPU 顶点解码：设备不支持顶点获取（bufferFeatures 无 VERTEX_BUFFER_BIT）的格式，
// 把一个顶点的属性字节解成 float4，经 R32G32B32A32_SFLOAT 顶点缓冲进 shader。
// 返回该格式的存储字节数；0 = 无解码路径（调用方按不支持报红）。out 恒写满 4 分量，
// 缺失分量按 NVN 顶点取数缺省补 (0,0,0,1)。
int nvn_vattr_cpu_decode(uint32_t nvn_format, const uint8_t *src, float out[4]);
// 与设备能力无关、必须走 CPU 解码的顶点格式：nvn_vk_format 映射出的整数存储格式
// 表达不了它的取数语义（32 位 UI2F/I2F，无 scaled 等价物）。返回 1 = 顶点路径必须解码；
// 这些格式在 nvn_vattr_cpu_decode 里都有实现，配套出现。
int nvn_vattr_must_cpu_decode(uint32_t nvn_format);
// NVNtextureView::SetFormat 的附件/采样覆盖合法性：只允许同兼容类的 8 位颜色格式互换。
// 输出 bpp/class；不合法返回 -1 并写 why（不回退 base 格式）。
int nvn_vk_format_override_class(VkFormat f, uint32_t *bpp, int *cls);
int nvn_vk_format_override_ok(VkFormat base, uint32_t nvn_format, VkFormat *out, char *why, size_t why_size);
// 纹理采样视图的格式选择：view_nvn_format == tex_nvn_format（视图就是纹理自身格式）时不是
// 格式覆盖，输出 base（解码后的图像/默认采样视图格式）；异格式才按兼容类表校验。
int nvn_vk_format_texview_ok(VkFormat base, uint32_t tex_nvn_format, uint32_t view_nvn_format,
                             VkFormat *out, char *why, size_t why_size);
#ifdef __cplusplus
}
#endif
