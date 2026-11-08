// F1.1/F1.2 真机 GPU 微例：采样 view 的 NVN 通道映射、view 在途引用与 LRU。
// 采样坐标固定 (0.5,0.5)、NEAREST/CLAMP、无混合/alpha test/颜色空间转换，输出 RGBA8 后逐像素核对。
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "nvn_vk_texcache.h"
#include "nvn_tex.h"

static int failures;
#define CHECK(c, ...) do { if (!(c)) { printf("FAIL "); printf(__VA_ARGS__); printf("\n"); failures++; } } while (0)

struct gpu {
    VkRenderPass pass;
    VkPipelineLayout layout;
    VkPipeline pipe;
    VkDescriptorSetLayout set_layout;
    VkDescriptorPool pool;
    VkSampler sampler;
    VkImage target;
    VkDeviceMemory target_mem;
    VkImageView target_view;
    VkFramebuffer fb;
};

static VkImage make_target(struct s2a_vk_device *d, VkDeviceMemory *mem) {
    VkImageCreateInfo ci = { VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO };
    ci.imageType = VK_IMAGE_TYPE_2D; ci.format = VK_FORMAT_R8G8B8A8_UNORM;
    ci.extent = (VkExtent3D){4, 4, 1}; ci.mipLevels = 1; ci.arrayLayers = 1;
    ci.samples = VK_SAMPLE_COUNT_1_BIT; ci.tiling = VK_IMAGE_TILING_OPTIMAL;
    ci.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
    ci.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    VkImage image = VK_NULL_HANDLE;
    if (vkCreateImage(d->device, &ci, NULL, &image) != VK_SUCCESS) return VK_NULL_HANDLE;
    VkMemoryRequirements req; vkGetImageMemoryRequirements(d->device, image, &req);
    VkMemoryAllocateInfo ai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO };
    ai.allocationSize = req.size;
    ai.memoryTypeIndex = s2a_vk_memory_type(d, req.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, NULL);
    if (ai.memoryTypeIndex == UINT32_MAX || vkAllocateMemory(d->device, &ai, NULL, mem) != VK_SUCCESS ||
        vkBindImageMemory(d->device, image, *mem, 0) != VK_SUCCESS) return VK_NULL_HANDLE;
    return image;
}

static VkShaderModule load_module(struct s2a_vk_device *d, const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return VK_NULL_HANDLE;
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    uint32_t *code = malloc((size_t)n);
    if (!code || fread(code, 1, (size_t)n, f) != (size_t)n) { free(code); fclose(f); return VK_NULL_HANDLE; }
    fclose(f);
    VkShaderModuleCreateInfo ci = { VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO };
    ci.codeSize = (size_t)n; ci.pCode = code;
    VkShaderModule m = VK_NULL_HANDLE;
    vkCreateShaderModule(d->device, &ci, NULL, &m);
    free(code);
    return m;
}

static int gpu_init(struct s2a_vk_device *d, struct gpu *g, const char *shaders) {
    VkAttachmentDescription att = {0};
    att.format = VK_FORMAT_R8G8B8A8_UNORM; att.samples = VK_SAMPLE_COUNT_1_BIT;
    att.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR; att.storeOp = VK_ATTACHMENT_STORE_OP_STORE;
    att.stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE; att.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
    att.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED; att.finalLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
    VkAttachmentReference ref = { 0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
    VkSubpassDescription sub = {0};
    sub.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS;
    sub.colorAttachmentCount = 1; sub.pColorAttachments = &ref;
    VkSubpassDependency dep = {0};
    dep.srcSubpass = VK_SUBPASS_EXTERNAL; dep.dstSubpass = 0;
    dep.srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    dep.dstStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    dep.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
    VkRenderPassCreateInfo rpi = { VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO };
    rpi.attachmentCount = 1; rpi.pAttachments = &att; rpi.subpassCount = 1; rpi.pSubpasses = &sub;
    rpi.dependencyCount = 1; rpi.pDependencies = &dep;
    if (vkCreateRenderPass(d->device, &rpi, NULL, &g->pass) != VK_SUCCESS) return -1;

    VkDescriptorSetLayoutBinding b = { 0, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1, VK_SHADER_STAGE_FRAGMENT_BIT, NULL };
    VkDescriptorSetLayoutCreateInfo sl = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO };
    sl.bindingCount = 1; sl.pBindings = &b;
    if (vkCreateDescriptorSetLayout(d->device, &sl, NULL, &g->set_layout) != VK_SUCCESS) return -1;
    VkPipelineLayoutCreateInfo pl = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO };
    pl.setLayoutCount = 1; pl.pSetLayouts = &g->set_layout;
    if (vkCreatePipelineLayout(d->device, &pl, NULL, &g->layout) != VK_SUCCESS) return -1;
    VkDescriptorPoolSize ps = { VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 64 };
    VkDescriptorPoolCreateInfo pci = { VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO };
    pci.maxSets = 64; pci.poolSizeCount = 1; pci.pPoolSizes = &ps;
    if (vkCreateDescriptorPool(d->device, &pci, NULL, &g->pool) != VK_SUCCESS) return -1;

    VkSamplerCreateInfo si = { VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO };
    si.magFilter = VK_FILTER_NEAREST; si.minFilter = VK_FILTER_NEAREST;
    si.mipmapMode = VK_SAMPLER_MIPMAP_MODE_NEAREST;
    si.addressModeU = si.addressModeV = si.addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    si.maxLod = 0.0f;
    if (vkCreateSampler(d->device, &si, NULL, &g->sampler) != VK_SUCCESS) return -1;

    char vp[512], fp[512];
    snprintf(vp, sizeof vp, "%s/view.vert.spv", shaders);
    snprintf(fp, sizeof fp, "%s/view.frag.spv", shaders);
    VkShaderModule vs = load_module(d, vp), fs = load_module(d, fp);
    if (!vs || !fs) return -1;
    VkPipelineShaderStageCreateInfo stages[2] = {0};
    stages[0].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[0].stage = VK_SHADER_STAGE_VERTEX_BIT; stages[0].module = vs; stages[0].pName = "main";
    stages[1].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT; stages[1].module = fs; stages[1].pName = "main";
    VkPipelineVertexInputStateCreateInfo vi = { VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO };
    VkPipelineInputAssemblyStateCreateInfo ia = { VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO };
    ia.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
    VkPipelineViewportStateCreateInfo vpst = { VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO };
    vpst.viewportCount = 1; vpst.scissorCount = 1;
    VkPipelineRasterizationStateCreateInfo rs = { VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO };
    rs.polygonMode = VK_POLYGON_MODE_FILL; rs.cullMode = VK_CULL_MODE_NONE;
    rs.frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE; rs.lineWidth = 1.0f;
    VkPipelineMultisampleStateCreateInfo ms = { VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO };
    ms.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;
    VkPipelineColorBlendAttachmentState cba = {0};
    cba.colorWriteMask = 0xf;
    VkPipelineColorBlendStateCreateInfo cb = { VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO };
    cb.attachmentCount = 1; cb.pAttachments = &cba;
    VkDynamicState dyn[2] = { VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR };
    VkPipelineDynamicStateCreateInfo ds = { VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO };
    ds.dynamicStateCount = 2; ds.pDynamicStates = dyn;
    VkGraphicsPipelineCreateInfo gp = { VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO };
    gp.stageCount = 2; gp.pStages = stages;
    gp.pVertexInputState = &vi; gp.pInputAssemblyState = &ia; gp.pViewportState = &vpst;
    gp.pRasterizationState = &rs; gp.pMultisampleState = &ms;
    gp.pColorBlendState = &cb; gp.pDynamicState = &ds;
    gp.layout = g->layout; gp.renderPass = g->pass;
    VkResult pr = vkCreateGraphicsPipelines(d->device, VK_NULL_HANDLE, 1, &gp, NULL, &g->pipe);
    vkDestroyShaderModule(d->device, vs, NULL); vkDestroyShaderModule(d->device, fs, NULL);
    if (pr != VK_SUCCESS) return -1;

    g->target = make_target(d, &g->target_mem);
    VkImageViewCreateInfo vci = { VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO };
    vci.image = g->target; vci.viewType = VK_IMAGE_VIEW_TYPE_2D; vci.format = VK_FORMAT_R8G8B8A8_UNORM;
    vci.subresourceRange = (VkImageSubresourceRange){ VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 };
    if (!g->target || vkCreateImageView(d->device, &vci, NULL, &g->target_view) != VK_SUCCESS) return -1;
    VkFramebufferCreateInfo fbi = { VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO };
    fbi.renderPass = g->pass; fbi.attachmentCount = 1; fbi.pAttachments = &g->target_view;
    fbi.width = 4; fbi.height = 4; fbi.layers = 1;
    if (vkCreateFramebuffer(d->device, &fbi, NULL, &g->fb) != VK_SUCCESS) return -1;
    return 0;
}

static int readback_rgba(struct s2a_vk_device *d, VkImage image, uint8_t out[4]) {
    VkBufferCreateInfo bi = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO };
    bi.size = 64; bi.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT;
    VkBuffer buf = VK_NULL_HANDLE;
    if (vkCreateBuffer(d->device, &bi, NULL, &buf) != VK_SUCCESS) return -1;
    VkMemoryRequirements req; vkGetBufferMemoryRequirements(d->device, buf, &req);
    VkMemoryAllocateInfo ai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO };
    ai.allocationSize = req.size;
    ai.memoryTypeIndex = s2a_vk_memory_type(d, req.memoryTypeBits,
        VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, NULL);
    VkDeviceMemory mem = VK_NULL_HANDLE; void *map = NULL;
    if (ai.memoryTypeIndex == UINT32_MAX || vkAllocateMemory(d->device, &ai, NULL, &mem) != VK_SUCCESS ||
        vkBindBufferMemory(d->device, buf, mem, 0) != VK_SUCCESS ||
        vkMapMemory(d->device, mem, 0, VK_WHOLE_SIZE, 0, &map) != VK_SUCCESS) return -1;
    VkCommandBufferAllocateInfo ca = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO };
    ca.commandPool = d->command_pool; ca.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY; ca.commandBufferCount = 1;
    VkCommandBuffer cmd = VK_NULL_HANDLE;
    VkFence fence = VK_NULL_HANDLE;
    VkFenceCreateInfo fi = { VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
    int rc = -1;
    if (vkAllocateCommandBuffers(d->device, &ca, &cmd) != VK_SUCCESS || vkCreateFence(d->device, &fi, NULL, &fence) != VK_SUCCESS) goto done;
    VkCommandBufferBeginInfo cbi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
    cbi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    vkBeginCommandBuffer(cmd, &cbi);
    VkBufferImageCopy region = {0};
    region.imageSubresource = (VkImageSubresourceLayers){ VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 };
    region.imageExtent = (VkExtent3D){ 4, 4, 1 };
    vkCmdCopyImageToBuffer(cmd, image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, buf, 1, &region);
    vkEndCommandBuffer(cmd);
    VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO };
    si.commandBufferCount = 1; si.pCommandBuffers = &cmd;
    if (vkQueueSubmit(d->queue, 1, &si, fence) == VK_SUCCESS &&
        vkWaitForFences(d->device, 1, &fence, VK_TRUE, UINT64_MAX) == VK_SUCCESS) {
        const uint8_t *p = (const uint8_t *)map + (2 * 4 + 2) * 4;
        memcpy(out, p, 4);
        rc = 0;
    }
done:
    if (fence) vkDestroyFence(d->device, fence, NULL);
    if (cmd) vkFreeCommandBuffers(d->device, d->command_pool, 1, &cmd);
    if (map) vkUnmapMemory(d->device, mem);
    if (mem) vkFreeMemory(d->device, mem, NULL);
    vkDestroyBuffer(d->device, buf, NULL);
    return rc;
}

static int sample(struct s2a_vk_device *d, struct gpu *g, VkImageView view, uint8_t out[4]) {
    VkDescriptorSetAllocateInfo ai = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO };
    ai.descriptorPool = g->pool; ai.descriptorSetCount = 1; ai.pSetLayouts = &g->set_layout;
    VkDescriptorSet set = VK_NULL_HANDLE;
    if (vkAllocateDescriptorSets(d->device, &ai, &set) != VK_SUCCESS) return -1;
    VkDescriptorImageInfo ii = { g->sampler, view, VK_IMAGE_LAYOUT_GENERAL };
    VkWriteDescriptorSet w = { VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET };
    w.dstSet = set; w.dstBinding = 0; w.descriptorCount = 1;
    w.descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER; w.pImageInfo = &ii;
    vkUpdateDescriptorSets(d->device, 1, &w, 0, NULL);

    VkCommandBufferAllocateInfo ca = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO };
    ca.commandPool = d->command_pool; ca.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY; ca.commandBufferCount = 1;
    VkCommandBuffer cmd = VK_NULL_HANDLE;
    if (vkAllocateCommandBuffers(d->device, &ca, &cmd) != VK_SUCCESS) return -1;
    VkCommandBufferBeginInfo cbi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
    cbi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    vkBeginCommandBuffer(cmd, &cbi);
    VkClearValue clear = {0};
    VkRenderPassBeginInfo rbi = { VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO };
    rbi.renderPass = g->pass; rbi.framebuffer = g->fb; rbi.renderArea = (VkRect2D){ {0, 0}, {4, 4} };
    rbi.clearValueCount = 1; rbi.pClearValues = &clear;
    vkCmdBeginRenderPass(cmd, &rbi, VK_SUBPASS_CONTENTS_INLINE);
    vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, g->pipe);
    vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, g->layout, 0, 1, &set, 0, NULL);
    VkViewport vp = { 0, 0, 4, 4, 0, 1 };
    VkRect2D sc = { {0, 0}, {4, 4} };
    vkCmdSetViewport(cmd, 0, 1, &vp);
    vkCmdSetScissor(cmd, 0, 1, &sc);
    vkCmdDraw(cmd, 3, 1, 0, 0);
    vkCmdEndRenderPass(cmd);
    vkEndCommandBuffer(cmd);
    VkFenceCreateInfo fi = { VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
    VkFence fence = VK_NULL_HANDLE;
    vkCreateFence(d->device, &fi, NULL, &fence);
    VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO };
    si.commandBufferCount = 1; si.pCommandBuffers = &cmd;
    int rc = -1;
    if (vkQueueSubmit(d->queue, 1, &si, fence) == VK_SUCCESS &&
        vkWaitForFences(d->device, 1, &fence, VK_TRUE, UINT64_MAX) == VK_SUCCESS) rc = 0;
    vkDestroyFence(d->device, fence, NULL);
    vkFreeCommandBuffers(d->device, d->command_pool, 1, &cmd);
    if (rc) return -1;
    return readback_rgba(d, g->target, out);
}

static void expect(struct s2a_vk_device *d, struct gpu *g, VkImageView view, const char *what, uint8_t r, uint8_t gg, uint8_t b, uint8_t a) {
    uint8_t p[4] = {0};
    if (sample(d, g, view, p)) { CHECK(0, "%s: sample failed", what); return; }
    CHECK(p[0] == r && p[1] == gg && p[2] == b && p[3] == a,
          "%s: got %u,%u,%u,%u want %u,%u,%u,%u", what, p[0], p[1], p[2], p[3], r, gg, b, a);
}

static void make_r8(tex_t *t, uint8_t *mem) {
    memset(t, 0, sizeof *t);
    t->magic = 0x00584554u; t->d.target = 1; t->d.format = NVN_FORMAT_R8;
    t->d.width = 4; t->d.height = 4; t->d.depth = 1; t->d.levels = 1;
    t->d.flags = 0x10; t->d.stride = 4; t->mem = mem; t->serial = 1;
    t->L.size = 16;
    memset(mem, 0x20, 16);
}
static int make_view(view_t *v, int set_fmt, int fmt, int set_levels, int bl, int nl,
                     int set_layers, int y, int ny, int set_swz, int r, int g, int b, int a) {
    memset(v, 0, sizeof *v);
    v->set_format = set_fmt; v->format = (uint16_t)fmt;
    v->set_levels = set_levels; v->base_level = (uint8_t)bl; v->nlevels = (uint8_t)nl;
    v->set_layers = set_layers; v->min_layer = (uint16_t)y; v->nlayers = (uint16_t)ny;
    v->set_swizzle = set_swz; v->swz[0] = (uint8_t)r; v->swz[1] = (uint8_t)g; v->swz[2] = (uint8_t)b; v->swz[3] = (uint8_t)a;
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) { printf("usage: %s <shader-dir>\n", argv[0]); return 2; }
    struct s2a_vk_device d; char why[192] = "";
    if (s2a_vk_device_create(&d, why, sizeof why)) { printf("FAIL device: %s\n", why); return 1; }
    struct nvn_vk_texcache c; nvn_vk_texcache_init(&c, &d, NULL, 0);
    struct gpu g; memset(&g, 0, sizeof g);
    if (gpu_init(&d, &g, argv[1])) { printf("FAIL gpu init: %s\n", why); return 1; }

    uint8_t mem[16];
    tex_t t; make_r8(&t, mem);
    struct nvn_vk_tex *tex = nvn_vk_texcache_get_tex(&c, &t, why, sizeof why);
    CHECK(tex != NULL, "R8 texture: %s", why);
    if (!tex) return 1;

    // 无 view：builder 未设置 swizzle → 恒等，R8 展开 (R,0,0,1)。
    expect(&d, &g, tex->view, "no view identity", 32, 0, 0, 255);

    view_t v;
    memset(&v, 0, sizeof v);   // 默认 view：所有覆盖位为 0，必须直接用整幅默认视图
    VkImageView dv0 = nvn_vk_texcache_view(&c, tex, &v, why, sizeof why);
    CHECK(dv0 == tex->view, "empty view returns the default whole-image view");
    if (dv0) expect(&d, &g, dv0, "empty default view", 32, 0, 0, 255);
    make_view(&v, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2);   // ONE,ONE,ONE,R
    VkImageView vv = nvn_vk_texcache_view(&c, tex, &v, why, sizeof why);
    CHECK(vv != NULL, "view (ONE,ONE,ONE,R): %s", why);
    if (vv) expect(&d, &g, vv, "view ONE,ONE,ONE,R", 255, 255, 255, 32);

    make_view(&v, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 4, 5);   // 显式 identity
    vv = nvn_vk_texcache_view(&c, tex, &v, why, sizeof why);
    CHECK(vv != NULL, "explicit identity view: %s", why);
    if (vv) expect(&d, &g, vv, "explicit identity", 32, 0, 0, 255);

    make_view(&v, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 1, 2);   // ZERO,ONE,ONE,R
    vv = nvn_vk_texcache_view(&c, tex, &v, why, sizeof why);
    CHECK(vv != NULL, "view ZERO,ONE,ONE,R: %s", why);
    if (vv) expect(&d, &g, vv, "view ZERO,ONE,ONE,R", 0, 255, 255, 32);

    // builder 的非恒等 swizzle：a=R → 默认视图 (R,0,0,R)。
    t.serial = 2; t.set_swz = 1; t.swz = (uint16_t)(2 | (3 << 3) | (4 << 6) | (2 << 9));
    struct nvn_vk_tex *tex2 = nvn_vk_texcache_get_tex(&c, &t, why, sizeof why);
    CHECK(tex2 != NULL, "R8 texture with builder a=R: %s", why);
    if (tex2) {
        expect(&d, &g, tex2->view, "builder a=R default view", 32, 0, 0, 32);
        make_view(&v, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2);
        VkImageView o = nvn_vk_texcache_view(&c, tex2, &v, why, sizeof why);
        CHECK(o != NULL, "view overrides builder: %s", why);
        if (o) expect(&d, &g, o, "view overrides builder", 255, 255, 255, 32);
    }

    // 非法枚举：准确失败，不退回 identity。
    make_view(&v, 0, 0, 0, 0, 0, 0, 0, 0, 1, 6, 1, 1, 2);
    why[0] = 0;
    vv = nvn_vk_texcache_view(&c, tex, &v, why, sizeof why);
    CHECK(vv == NULL && strstr(why, "valid 0..5") != NULL, "illegal view swizzle rejected: %s", why);
    t.serial = 3; t.set_swz = 1; t.swz = 6;   // packed 字段里的 6 同样非法
    why[0] = 0;
    tex2 = nvn_vk_texcache_get_tex(&c, &t, why, sizeof why);
    CHECK(tex2 == NULL && strstr(why, "valid 0..5") != NULL, "illegal builder swizzle rejected: %s", why);

    // ---- F1.2：view 在途引用 + LRU（脚本把 debug.s2a.view_max 设为 3（2 个附加槽））----
    t.serial = 1; t.set_swz = 0; t.swz = 0;
    tex = nvn_vk_texcache_get_tex(&c, &t, why, sizeof why);
    CHECK(tex != NULL, "tex for view LRU: %s", why);
    struct nvn_vk_tex_view_stats st0, st1;
    nvn_vk_texcache_view_stats(&st0);
    make_view(&v, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2);
    VkImageView a = nvn_vk_texcache_view(&c, tex, &v, why, sizeof why);
    make_view(&v, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 1, 2);
    VkImageView b = nvn_vk_texcache_view(&c, tex, &v, why, sizeof why);
    CHECK(a && b, "two views fit in capacity 2: %s", why);
    CHECK(a && nvn_vk_texcache_pin_view(tex, a) == 0, "pin view A");
    CHECK(b && nvn_vk_texcache_pin_view(tex, b) == 0, "pin view B");
    make_view(&v, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 0, 1, 2);
    why[0] = 0;
    VkImageView cview = nvn_vk_texcache_view(&c, tex, &v, why, sizeof why);
    CHECK(cview == NULL && strstr(why, "in-flight") != NULL, "all-pinned view cache rejected: %s", why);
    nvn_vk_texcache_view_stats(&st1);
    CHECK(st1.pinned_full_rejects > st0.pinned_full_rejects, "pinned-full counter");
    nvn_vk_texcache_unpin_view(tex, a);
    why[0] = 0;
    cview = nvn_vk_texcache_view(&c, tex, &v, why, sizeof why);
    CHECK(cview != NULL, "after unpin LRU reclaims a finished view: %s", why);
    if (cview) expect(&d, &g, cview, "reclaimed slot view", 255, 0, 255, 32);
    if (b) expect(&d, &g, b, "still-pinned view B", 0, 255, 255, 32);
    nvn_vk_texcache_unpin_view(tex, b);
    nvn_vk_texcache_view_stats(&st1);
    CHECK(st1.evicted > st0.evicted, "evicted counter");

    // GPU 写入后换 view：仍读 GPU 内容，不得用 CPU 镜像重建/覆盖。
    uint8_t red[64];
    for (int i = 0; i < 64; i += 4) { red[i] = 255; red[i + 1] = 0; red[i + 2] = 0; red[i + 3] = 255; }
    tex_t ct; memset(&ct, 0, sizeof ct);
    ct.magic = 0x00584554u; ct.d.target = 1; ct.d.format = NVN_FORMAT_RGBA8;
    ct.d.width = 4; ct.d.height = 4; ct.d.depth = 1; ct.d.levels = 1;
    ct.d.flags = 0x10; ct.d.stride = 16; ct.mem = red; ct.serial = 10; ct.L.size = 64;
    struct nvn_vk_tex *ctex = nvn_vk_texcache_get_tex(&c, &ct, why, sizeof why);
    CHECK(ctex != NULL, "RGBA8 texture for GPU write: %s", why);
    if (ctex) {
        VkCommandBuffer cmd = VK_NULL_HANDLE;
        VkCommandBufferAllocateInfo ca = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO };
        ca.commandPool = d.command_pool; ca.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY; ca.commandBufferCount = 1;
        VkClearColorValue blue = { .float32 = { 0.0f, 0.0f, 1.0f, 1.0f } };
        VkImageSubresourceRange range = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 };
        if (vkAllocateCommandBuffers(d.device, &ca, &cmd) == VK_SUCCESS) {
            VkCommandBufferBeginInfo bi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
            bi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
            vkBeginCommandBuffer(cmd, &bi);
            vkCmdClearColorImage(cmd, ctex->image, VK_IMAGE_LAYOUT_GENERAL, &blue, 1, &range);
            vkEndCommandBuffer(cmd);
            VkFenceCreateInfo fi = { VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
            VkFence fence = VK_NULL_HANDLE; vkCreateFence(d.device, &fi, NULL, &fence);
            VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO };
            si.commandBufferCount = 1; si.pCommandBuffers = &cmd;
            int ok = vkQueueSubmit(d.queue, 1, &si, fence) == VK_SUCCESS &&
                     vkWaitForFences(d.device, 1, &fence, VK_TRUE, UINT64_MAX) == VK_SUCCESS;
            vkDestroyFence(d.device, fence, NULL);
            vkFreeCommandBuffers(d.device, d.command_pool, 1, &cmd);
            CHECK(ok, "GPU clear of sampled image");
            if (ok) nvn_vk_texcache_mark_written(&c, ctex->image);
        }
        expect(&d, &g, ctex->view, "GPU-written texture through a new lookup", 0, 0, 255, 255);
    }

    // F2.3 附件格式覆盖：同一 SRGB backing 上申请 UNORM 附件视图，返回格式必须是真的覆写格式；
    // 不同兼容类、深度/模板覆盖都必须准确拒绝。
    {
        uint8_t srgb[64];
        for (int i = 0; i < 64; i += 4) { srgb[i] = 10; srgb[i + 1] = 20; srgb[i + 2] = 30; srgb[i + 3] = 255; }
        tex_t st; memset(&st, 0, sizeof st);
        st.magic = 0x00584554u; st.d.target = 1; st.d.format = NVN_FORMAT_RGBA8_SRGB;
        st.d.width = 4; st.d.height = 4; st.d.depth = 1; st.d.levels = 1;
        st.d.flags = 0x10; st.d.stride = 16; st.mem = srgb; st.serial = 20; st.L.size = 64;
        struct nvn_vk_tex *stex = nvn_vk_texcache_get_tex(&c, &st, why, sizeof why);
        CHECK(stex != NULL, "SRGB texture: %s", why);
        if (stex) {
            view_t ov;
            make_view(&ov, 1, NVN_FORMAT_RGBA8, 1, 0, 1, 1, 0, 1, 0, 0, 0, 0, 0);
            VkFormat fmt = VK_FORMAT_UNDEFINED;
            why[0] = 0;
            VkImageView av = nvn_vk_texcache_attachment_view(&c, stex, &ov, &fmt, why, sizeof why);
            CHECK(av != NULL && fmt == VK_FORMAT_R8G8B8A8_UNORM,
                  "UNORM attachment view over SRGB backing: view=%p fmt=%d why=%s", (void *)av, (int)fmt, why);
            make_view(&ov, 1, NVN_FORMAT_RGBA16F, 1, 0, 1, 1, 0, 1, 0, 0, 0, 0, 0);
            why[0] = 0;
            av = nvn_vk_texcache_attachment_view(&c, stex, &ov, &fmt, why, sizeof why);
            CHECK(av == NULL && strstr(why, "compatibility class") != NULL,
                  "wrong attachment override class rejected: %s", why);
        }
        uint8_t depth_mem[4096]; memset(depth_mem, 0, sizeof depth_mem);
        tex_t dt; memset(&dt, 0, sizeof dt);
        dt.magic = 0x00584554u; dt.d.target = 1; dt.d.format = NVN_FORMAT_DEPTH24_STENCIL8;
        dt.d.width = 8; dt.d.height = 8; dt.d.depth = 1; dt.d.levels = 1;
        dt.mem = depth_mem; dt.serial = 21; dt.L.size = sizeof depth_mem;
        struct nvn_vk_tex *dtex = nvn_vk_texcache_get_tex(&c, &dt, why, sizeof why);
        CHECK(dtex != NULL, "depth texture: %s", why);
        if (dtex) {
            view_t dv;
            make_view(&dv, 1, NVN_FORMAT_DEPTH32F, 1, 0, 1, 1, 0, 1, 0, 0, 0, 0, 0);
            char dwhy[192] = "";
            VkFormat dfmt = VK_FORMAT_UNDEFINED;
            VkImageView dav = nvn_vk_texcache_attachment_view(&c, dtex, &dv, &dfmt, dwhy, sizeof dwhy);
            CHECK(dav == NULL && strstr(dwhy, "mutable") != NULL,
                  "depth attachment format override rejected: %s", dwhy);
        }
    }

    s2a_vk_device_destroy(&d, 0);
    if (failures) { printf("nvn-vk texview: %d FAILURES\n", failures); return 1; }
    printf("PASS nvn-vk texview: swizzle mapping, illegal enums, in-flight view pins, GPU content preserved\n");
    return 0;
}
