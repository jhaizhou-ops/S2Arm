// 新后端管线缓存：C2 程序 blob（NVKP）→ VkPipeline，按 blob 内容 + 颜色格式复用。
#pragma once
#include <stddef.h>
#include <vulkan/vulkan.h>
#include "vk_device.h"

#ifdef __cplusplus
extern "C" {
#endif
// 一次绘制的顶点输入布局（来自 NVN 顶点状态）；缓存身份包含它。
struct nvn_vk_vertex_layout {
    uint32_t binding_count, attribute_count;
    VkVertexInputBindingDescription bindings[8];
    VkVertexInputAttributeDescription attributes[16];
};
struct nvn_vk_pipeline_cache {
    struct s2a_vk_device *d;
    struct {
        uint64_t key; VkFormat color;
        VkShaderModule mod[4]; uint32_t nmod;
        VkDescriptorSetLayout setl[4]; VkPipelineLayout playout;
        VkRenderPass pass; VkPipeline pipe;
        VkDescriptorPool pool; VkDescriptorSet sets[4];
        int valid;
    } slots[16];
    uint32_t created, reused;
};
void nvn_vk_pipeline_init(struct nvn_vk_pipeline_cache *c, struct s2a_vk_device *d);
void nvn_vk_pipeline_destroy(struct nvn_vk_pipeline_cache *c);
// 命中/新建；失败返回 VK_NULL_HANDLE 并写 why。
VkPipeline nvn_vk_pipeline_get(struct nvn_vk_pipeline_cache *c, const char *blob_path, VkFormat color,
                               const struct nvn_vk_vertex_layout *vl, char *why, size_t why_size);
VkRenderPass nvn_vk_pipeline_render_pass(struct nvn_vk_pipeline_cache *c, VkPipeline pipe);
// 把一次全屏三角形画到 view（颜色附件，宽 w 高 h）：录命令、bind 缓存的 sets、提交并等完成。
// vertices 为 vec4 位置数组；ubo 非空时写入 set0/bind0。返回 0 成功。
int nvn_vk_pipeline_draw(struct nvn_vk_pipeline_cache *c, VkPipeline pipe, VkImageView view, uint32_t w, uint32_t h,
                         const void *vertices, size_t vertex_bytes, VkBuffer ubo, VkDeviceSize ubo_size);
// 把绘制录进给定命令缓冲（目标已处于 COLOR_ATTACHMENT_OPTIMAL；view 对应 w×h）：
// 调用方负责前后的 layout 转换、信号量与提交（present 路径复用这段）。
int nvn_vk_pipeline_record(struct nvn_vk_pipeline_cache *c, VkPipeline pipe, VkCommandBuffer cmd,
                           VkImageView view, uint32_t w, uint32_t h, VkBuffer vb, VkBuffer ubo, VkDeviceSize ubo_size,
                           VkFramebuffer *fb_out);
// 该管线的 4 个描述符集（按 set 号）；找不到返回 -1。
int nvn_vk_pipeline_sets(struct nvn_vk_pipeline_cache *c, VkPipeline pipe, VkDescriptorSet sets[4]);
// 更新该管线的 UBO / combined sampler 描述符；找不到管线/绑定返回 -1。
int nvn_vk_pipeline_update_ubo(struct nvn_vk_pipeline_cache *c, VkPipeline pipe, uint32_t set, uint32_t binding,
                               VkBuffer buffer, VkDeviceSize offset, VkDeviceSize range);
int nvn_vk_pipeline_update_tex(struct nvn_vk_pipeline_cache *c, VkPipeline pipe, uint32_t set, uint32_t binding,
                               VkImageView view, VkSampler sampler);
#ifdef __cplusplus
}
#endif
