// OP_COPY_T2T（NVN CopyTextureToTexture / Downsample）的回放计划：纯函数，不碰 Vulkan 句柄与设备。
// 输入 = 记录里的视图/区域/flags + 双方纹理事实；输出 = vkCmdCopyImage 或 vkCmdBlitImage
// 需要的一切（子资源选择、偏移、翻转盒）。不支持的组合返回 -1 并在 why 写明原因——
// 调用方原样报红，不兜底成功。
// 语义对齐 Metal 路径（nvn_mtl.m copy_t2t_）：同尺寸同格式直拷；缩放 / 格式变 / MIRROR_X|Y
// 走 blit（Metal 走 draw；Vulkan 的 blit 自带缩放与翻转）；ENGINE_2D 只是引擎选择提示；
// DM_COPY_RESOLVE（Downsample 记录 = 多采样解析到单采样）：双方单采样同格式同尺寸时是
// 普通全图拷；源多采样、目标单采样、同格式同尺寸时发 vkCmdResolveImage；别的样本数
// 组合（解析进 MS、MS->MS）仍明确报红。
#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define S2A_T2T_ASPECT_COLOR   1u
#define S2A_T2T_ASPECT_DEPTH   2u
#define S2A_T2T_ASPECT_STENCIL 4u

enum s2a_t2t_op { S2A_T2T_COPY = 0, S2A_T2T_BLIT_NEAREST = 1, S2A_T2T_BLIT_LINEAR = 2,
                  S2A_T2T_RESOLVE = 3 };

// 已解析纹理的事实（记录内嵌快照 + VkImage 事实的并集）。0 = 未知。
struct s2a_t2t_tex {
    uint32_t nvn_format;    // NVN 格式号；0 = 未知
    uint32_t vk_format;     // VkFormat 数值；0 = 未知
    uint32_t width, height; // level 0 尺寸
    uint32_t depth;         // 3D 深度；非 3D 恒 1
    uint32_t layers;        // 数组层数（cube 含 6 面）；3D 恒 1；0 = 未知按 1
    uint32_t levels;        // mip 数；0 = 未知按 1
    int is_3d;              // target == NVN_TEXTURE_TARGET_3D（快照缺失时按 depth>1 推）
    int ms;                 // samples > 1（Android 建不出 MS；快照有 samples>1 时置位防御）
    int stencil_mode;       // 纹理自身按 stencil 面读取（TextureBuilderSetDepthStencilMode STENCIL）
    int target;             // NVN textureTarget；-1 = 未知；BUFFER 目标会明确拒绝
};

// 记录里的 NVNtextureView（has==0 时其余字段忽略）
struct s2a_t2t_view {
    int has;
    int base_level;            // set_levels ? base_level : 0
    int nlevels;               // set_levels ? nlevels : 0（拷贝只作用于 base_level）
    int min_layer;             // set_layers ? min_layer : 0
    int has_format;
    uint32_t nvn_format;
    int has_dsmode;            // set_dsmode 出现过（区分「视图选了 depth」与「没选」）
    int dsmode_stencil;        // has_dsmode && mode == NVN_TEXTURE_DEPTH_STENCIL_MODE_STENCIL
    int has_target;
    uint32_t target;
};

struct s2a_t2t_region { int32_t x, y, z, w, h, d; };

struct s2a_t2t_plan {
    int op;                         // s2a_t2t_op
    uint32_t src_aspect, dst_aspect;    // S2A_T2T_ASPECT_*
    uint32_t src_level, dst_level;
    uint32_t src_base_layer, dst_base_layer;   // 非 3D：首个数组层；3D 恒 0
    uint32_t layer_count;                       // 非 3D：本次拷的连续层数；3D 恒 1
    // S2A_T2T_COPY：src_offset/dst_offset + extent（3D 的 z 是真深度）
    // BLIT_*：src_box/dst_box 两角（dst_box 在镜像轴上反向 = Vulkan 的翻转 blit）
    int32_t src_offset[3], dst_offset[3];
    uint32_t extent[3];
    int32_t src_box[2][3], dst_box[2][3];
};

// 0 = 计划成立；非 0 = 不支持/非法，why 写具体原因。
int s2a_t2t_plan(const struct s2a_t2t_tex *src, const struct s2a_t2t_view *sv, const struct s2a_t2t_region *sr,
                 const struct s2a_t2t_tex *dst, const struct s2a_t2t_view *dv, const struct s2a_t2t_region *dr,
                 uint32_t flags, struct s2a_t2t_plan *out, char *why, size_t why_size);

#ifdef __cplusplus
}
#endif
