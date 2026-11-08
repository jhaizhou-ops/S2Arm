// NVN ReadTexels（纹理读回）的纯几何/打包换算。
//
// 这个文件不依赖 Vulkan、NVN 头或任何宿主 API：调用方把 NVN 纹理描述与 NVNcopyRegion
// 换成下面的整数字段，plan 负责
//   · 子资源与区域合法性（level / layer / x,y,z / width,height,depth 对 level 尺寸）；
//   · NVN 的行距（row）与层距（img）语义：0 = 按块行字节数 / 按行距 × 块行数 紧排；
//   · 块压缩格式（BC/ASTC/ETC2）的块对齐与块行字节数；
//   · 每个层/切片落到 VkBufferImageCopy 的 (bufferOffset / imageSubresource / imageOffset /
//     imageExtent)，以及读回数据写进 dst 时的偏移。
// 真机读回（GPU 图像路径 + guest 内存路径）与宿主单测共用这一份换算，测试直接编本文件。
#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// NVNcopyRegion 的整数值（前端按值拷贝过来的 ABI 结构）。
struct nvn_vk_rb_region { int32_t x, y, z; int32_t width, height, depth; };

// 读回需要的纹理几何（来自 tex_t / nvn_texdesc 与 nvn_tex_layout）。
struct nvn_vk_rb_desc {
    uint32_t nvn_format;
    int32_t target;        // NVNtextureTarget（2 = 3D）
    // nvn_fmt_bpb() 的结果（每块字节数、块宽高）。放在这里而不是在 plan 里重算：
    // 格式表只有 nvn_fmt_info 一份，plan 不再抄第二份。
    int32_t bpb, bw, bh;
    uint32_t flags;        // NVNtextureFlags（0x10/0x40 = LINEAR / LINEAR_RENDER_TARGET）
    uint32_t width, height, depth, levels;
    uint32_t layers;       // nvn_tex_layout.layers（数组/立方体层数；0 视为 1）
};

struct nvn_vk_rb_plan {
    uint32_t level, layer0;
    int is3d;
    int32_t bpb, bw, bh;         // 每块字节数、块宽高（未压缩格式都是 1）
    uint32_t level_w, level_h, level_d;     // 该 level 的尺寸（3D 的 level_d = depth>>level）
    uint32_t x, y, z;            // 区域内 texel 原点
    uint32_t w, h;               // 区域内 texel 尺寸（width / height）
    uint32_t nz;                 // 层/切片数（depth，0 = 1）
    size_t dst_row, dst_img;     // dst 的行距/层距（已按 NVN 默认补全）
    uint32_t block_cols, block_rows;   // ceil(w/bw) / ceil(h/bh)
    uint32_t copy_row_bytes;     // block_cols * bpb —— 紧排的一行字节数
    size_t copy_bytes;           // copy_row_bytes * block_rows —— 每个层/切片的字节数
    uint32_t staging_stride;     // copy_bytes 向上对齐 16 后的每层/切片 staging 间距
    size_t staging_bytes;        // staging_stride * nz
};

// 第 z 个层/切片的落点。
struct nvn_vk_rb_slice {
    uint32_t image_layer;   // VkBufferImageCopy.imageSubresource.baseArrayLayer
    uint32_t image_z;       // VkBufferImageCopy.imageOffset.z（仅 3D 用；非 3D 恒 0）
    size_t dst_offset;      // 写进 dst 的字节偏移
    size_t staging_offset;  // staging buffer 的字节偏移
};

#define NVN_VK_RB_WHY_MAX 320

// 校验并换算。成功返回 0；失败返回 -1 并把可定位原因（格式/尺寸/level/layer/区域/行距）
// 写进 why。out 只在成功时有意义。
int nvn_vk_readback_plan(const struct nvn_vk_rb_desc *d, unsigned level, unsigned layer0,
                         const struct nvn_vk_rb_region *r, size_t row, size_t img,
                         struct nvn_vk_rb_plan *out, char *why, size_t why_size);

// 第 z 个层/切片的 (image_layer, image_z, dst 偏移, staging 偏移)。z < plan->nz。
void nvn_vk_readback_slice(const struct nvn_vk_rb_plan *p, unsigned z, struct nvn_vk_rb_slice *out);

// dst 写入所需的最后一字节偏移（含行内宽度）：nz*img 之外的真实上界，供调用方核对缓冲区。
// 返回 (nz-1)*dst_img + (block_rows-1)*dst_row + copy_row_bytes。
size_t nvn_vk_readback_dst_extent(const struct nvn_vk_rb_plan *p);

#ifdef __cplusplus
}
#endif
