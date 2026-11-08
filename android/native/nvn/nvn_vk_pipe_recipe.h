// GPU 管线的完整规范配方（用于管线对象缓存的命中判据）。
//
// 背景（方案 §8.5.11）：`fd_pipe_key` 原来只用 64 位 FNV 命中，命中时不比较完整配方——
// 两个只差 blend/深度/顶点输入/附件格式的管线一旦撞上同一 hash，就会复用不兼容的 VkPipeline。
// 这里把“构建这条管线真正读取的全部输入”写成可逐字节比较的规范结构：
//   * 程序内容身份（完整结果 SHA-256）与 request_id（**只作日志/定位，不参与判据**：
//     跨局采纳时 request_id 可能变化，参与判据会让“预热建好、真实绘制仍 miss”）；
//   * 设备句柄（设备代际；release_device 会清缓存）与布局策略版本；
//   * 全部已绑定的 NVN 状态对象原文、逐 target 的混合状态、顶点属性/流、prim、逐槽颜色附件格式、
//     空槽掩码与 depth_only（决定管线是否带 blend attachment 及每槽的写掩码/混合）。
// 命中 = hash 相等且整份结构逐字节相等。结构先 memset 再填，全部字段都是显式标量/数组，
// 没有需要单独处理的外部指针；填充后不存在未初始化 padding。
#pragma once
#include <stddef.h>
#include <stdint.h>

#include "vk_record.h"

#ifdef __cplusplus
extern "C" {
#endif

// 布局/配方的语义版本：改变管线 layout 的构造策略时递增，旧缓存条目自然不命中。
#define NVK_PIPE_LAYOUT_POLICY 2u

struct nvk_pipe_recipe {
    uint32_t layout_policy;
    uint32_t rt_count;
    uint32_t prim;
    uint32_t state_seen;
    uint32_t rt_color_count;         // subpass colorAttachmentCount（最高绑定槽 + 1，含空洞）
    uint32_t rt_bound_mask;          // 参与槽（bit i）；空洞/被丢弃的重复槽为 0
    uint32_t rt_fmt[8];              // 逐槽附件视图格式（未参与槽保持 VK_FORMAT_UNDEFINED）
    uint32_t depth_fmt;
    uint32_t has_depth;
    uint32_t depth_only;
    uint32_t clear_mask;             // 深度/模板清除掩码：决定 render pass 的 loadOp 变体（预热要建同一条 pass）
    uint64_t device;                 // VkDevice（设备代际；同进程重建设备后不命中）
    char request_id[40];             // 阶段 key 组（只作定位；hash/整份比较都跳过本字段）
    uint8_t prog_sha[32];            // 程序结果完整内容身份
    uint8_t state_obj[6][24];        // 已绑定状态对象原文（kind 0..5）
    uint8_t blend_obj[8][24];        // 按 NVNblendState.target 分槽的混合状态原文
    uint8_t blend_seen;
    uint32_t vattr[32][3];           // {format, offset, stream}，OP_BIND_VATTR 原样
    uint32_t vstride[16];
    uint32_t vdivisor[16];
};

void nvk_pipe_recipe_fill(struct nvk_pipe_recipe *r, const struct s2a_record_draw_state *st,
                          const char *request_id, const uint8_t prog_sha[32],
                          const uint32_t rt_fmt[8], uint32_t rt_color_count, uint32_t rt_bound_mask,
                          uint32_t depth_fmt, int has_depth, int depth_only, uint64_t device);
uint64_t nvk_pipe_recipe_hash(const struct nvk_pipe_recipe *r);
// hash 相等只是预筛；这里才是判据。返回 1 = 同一配方。
int nvk_pipe_recipe_match(const struct nvk_pipe_recipe *a, const struct nvk_pipe_recipe *b);
// 缓存命中判据：key 相等 **且** 完整配方逐字节相等。单独暴露是为了让回归能注入
// “hash 撞了但配方不同”的反例，证明命中不会只看 hash。
int nvk_pipe_recipe_hit(uint64_t cached_key, const struct nvk_pipe_recipe *cached,
                        uint64_t key, const struct nvk_pipe_recipe *r);

#ifdef __cplusplus
}
#endif
