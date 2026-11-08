// nvn_vk_be 第一片：C2 编译输出（program blob）→ 新 Vulkan 后端 → 画一个全屏三角形 → 读回。
// 不经过 d2r 引擎、不读 .xgs；失败明确打印 VkResult/原因，不跳过绘制。
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>
#include "vk_device.h"
#include "nvn_vk_format.h"
#include "nvn_vk_texcache.h"

#define CHECK(x) do { VkResult r_ = (x); if (r_ != VK_SUCCESS) { printf("FAIL %s: VkResult %d\n", #x, (int)r_); return 1; } } while (0)

struct blob {
    uint32_t magic, version, nstage, nbind;
    struct { uint32_t stage, size; const uint8_t *spv; } st[4];
    struct { uint32_t set, binding, kind, count; } b[16];
};

static int load_blob(const char *path, struct blob *b) {
    FILE *f = fopen(path, "rb"); if (!f) { printf("FAIL open %s\n", path); return -1; }
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    uint8_t *p = malloc((size_t)n); if (!p || fread(p, 1, (size_t)n, f) != (size_t)n) { fclose(f); return -1; }
    fclose(f);
    if (n < 16 || memcmp(p, "NVKP", 4)) { printf("FAIL blob magic\n"); return -1; }
    memcpy(&b->version, p + 4, 4); memcpy(&b->nstage, p + 8, 4); memcpy(&b->nbind, p + 12, 4);
    if (b->version != 1 || b->nstage > 4 || b->nbind > 16) { printf("FAIL blob header\n"); return -1; }
    size_t at = 16;
    for (uint32_t i = 0; i < b->nstage; i++) {
        if (at + 8 > (size_t)n) return -1;
        memcpy(&b->st[i].stage, p + at, 4); memcpy(&b->st[i].size, p + at + 4, 4); at += 8;
        if (at + b->st[i].size > (size_t)n) return -1;
        b->st[i].spv = p + at; at += b->st[i].size + ((4 - b->st[i].size % 4) % 4);
    }
    for (uint32_t i = 0; i < b->nbind; i++) {
        if (at + 16 > (size_t)n) return -1;
        memcpy(&b->b[i], p + at, 16); at += 16;
    }
    return 0;
}

static uint32_t mem_type(struct s2a_vk_device *d, uint32_t bits, VkMemoryPropertyFlags want) {
    uint32_t t = s2a_vk_memory_type(d, bits, want, NULL);
    return t;
}

int main(int argc, char **argv) {
    if (argc < 2) { printf("usage: %s <program.blob> [texture.tex]\n", argv[0]); return 2; }
    struct blob b;
    if (load_blob(argv[1], &b)) return 1;
    // 可选：真实纹理描述（magic NVNT + nvn_format + w + h + tight data）
    uint32_t tex_fmt = 0, tex_w = 0, tex_h = 0, tex_bytes = 0, tw = 1, th = 1; uint8_t *tex_data = NULL;
    if (argc >= 3) {
        FILE *tf = fopen(argv[2], "rb"); if (!tf) { printf("FAIL open %s\n", argv[2]); return 1; }
        uint8_t hdr[20];
        if (fread(hdr, 1, sizeof hdr, tf) != sizeof hdr || memcmp(hdr, "NVNT", 4)) { printf("FAIL tex magic\n"); return 1; }
        memcpy(&tex_fmt, hdr + 4, 4); memcpy(&tex_w, hdr + 8, 4); memcpy(&tex_h, hdr + 12, 4);
        uint32_t bytes; memcpy(&bytes, hdr + 16, 4); tex_bytes = bytes;
        tex_data = malloc(bytes); if (!tex_data || fread(tex_data, 1, bytes, tf) != bytes) { printf("FAIL tex data\n"); return 1; }
        fclose(tf);
        printf("texture: nvn=0x%x %ux%u %u B -> vk=%d\n", tex_fmt, tex_w, tex_h, bytes, (int)nvn_vk_format(tex_fmt));
    }
    uint32_t tex_set = 0, tex_binding = 0; int has_tex = 0;
    for (uint32_t i = 0; i < b.nbind; i++) if (b.b[i].kind == 2) { has_tex = 1; tex_set = b.b[i].set; tex_binding = b.b[i].binding; }

    struct s2a_vk_device d; char why[192] = "";
    if (s2a_vk_device_create(&d, why, sizeof why)) { printf("FAIL device: %s\n", why); return 1; }
    printf("device: %s / %s\n", d.driver_name, d.driver_info);
    struct nvn_vk_texcache cache; nvn_vk_texcache_init(&cache, &d, NULL, 0);

    const VkFormat fmt = VK_FORMAT_R8G8B8A8_UNORM;
    const uint32_t W = 64, H = 64;

    VkImageCreateInfo ici = { VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO };
    ici.imageType = VK_IMAGE_TYPE_2D; ici.format = fmt; ici.extent = (VkExtent3D){W, H, 1};
    ici.mipLevels = 1; ici.arrayLayers = 1; ici.samples = VK_SAMPLE_COUNT_1_BIT;
    ici.tiling = VK_IMAGE_TILING_OPTIMAL; ici.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
    ici.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    VkImage img; CHECK(vkCreateImage(d.device, &ici, NULL, &img));
    VkMemoryRequirements mr; vkGetImageMemoryRequirements(d.device, img, &mr);
    VkMemoryAllocateInfo mai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO };
    mai.allocationSize = mr.size; mai.memoryTypeIndex = mem_type(&d, mr.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    VkDeviceMemory img_mem; CHECK(vkAllocateMemory(d.device, &mai, NULL, &img_mem));
    CHECK(vkBindImageMemory(d.device, img, img_mem, 0));
    VkImageViewCreateInfo vci = { VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO };
    vci.image = img; vci.viewType = VK_IMAGE_VIEW_TYPE_2D; vci.format = fmt;
    vci.subresourceRange = (VkImageSubresourceRange){VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
    VkImageView view; CHECK(vkCreateImageView(d.device, &vci, NULL, &view));

    VkAttachmentDescription att = {0};
    att.format = fmt; att.samples = VK_SAMPLE_COUNT_1_BIT;
    att.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR; att.storeOp = VK_ATTACHMENT_STORE_OP_STORE;
    att.stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE; att.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
    att.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED; att.finalLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
    VkAttachmentReference ref = {0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
    VkSubpassDescription sub = {0};
    sub.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS; sub.colorAttachmentCount = 1; sub.pColorAttachments = &ref;
    VkRenderPassCreateInfo rpci = { VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO };
    rpci.attachmentCount = 1; rpci.pAttachments = &att; rpci.subpassCount = 1; rpci.pSubpasses = &sub;
    VkRenderPass pass; CHECK(vkCreateRenderPass(d.device, &rpci, NULL, &pass));
    VkFramebufferCreateInfo fbci = { VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO };
    fbci.renderPass = pass; fbci.attachmentCount = 1; fbci.pAttachments = &view; fbci.width = W; fbci.height = H; fbci.layers = 1;
    VkFramebuffer fb; CHECK(vkCreateFramebuffer(d.device, &fbci, NULL, &fb));

    // 4 个 set 的 layout（C2 的 binding 用 set 号）；当前程序只用 set 0 的 support UBO。
    VkDescriptorSetLayout setl[4]; VkDescriptorSetLayoutBinding bnd[16]; uint32_t per_set[4] = {0,0,0,0};
    memset(bnd, 0, sizeof bnd);
    for (uint32_t i = 0; i < b.nbind; i++) {
        VkDescriptorSetLayoutBinding *v = &bnd[i];
        v->binding = b.b[i].binding;
        v->descriptorType = b.b[i].kind == 2 ? VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER : VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
        v->descriptorCount = b.b[i].count; v->stageFlags = VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT;
        per_set[b.b[i].set]++;
    }
    uint32_t off = 0;
    for (int s = 0; s < 4; s++) {
        VkDescriptorSetLayoutCreateInfo lci = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO };
        lci.bindingCount = per_set[s]; lci.pBindings = bnd + off; off += per_set[s];
        CHECK(vkCreateDescriptorSetLayout(d.device, &lci, NULL, &setl[s]));
    }
    VkPipelineLayoutCreateInfo plc = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO };
    plc.setLayoutCount = 4; plc.pSetLayouts = setl;
    VkPipelineLayout playout; CHECK(vkCreatePipelineLayout(d.device, &plc, NULL, &playout));

    VkShaderModule mod[4]; VkPipelineShaderStageCreateInfo ss[4];
    for (uint32_t i = 0; i < b.nstage; i++) {
        VkShaderModuleCreateInfo smci = { VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO };
        smci.codeSize = b.st[i].size; smci.pCode = (const uint32_t *)b.st[i].spv;
        CHECK(vkCreateShaderModule(d.device, &smci, NULL, &mod[i]));
        ss[i] = (VkPipelineShaderStageCreateInfo){ VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO };
        ss[i].stage = b.st[i].stage == 0 ? VK_SHADER_STAGE_VERTEX_BIT : VK_SHADER_STAGE_FRAGMENT_BIT;
        ss[i].module = mod[i]; ss[i].pName = "main";
    }
    VkVertexInputBindingDescription vbind = {0, 16, VK_VERTEX_INPUT_RATE_VERTEX};
    VkVertexInputAttributeDescription vattr = {0, 0, VK_FORMAT_R32G32B32A32_SFLOAT, 0};
    VkPipelineVertexInputStateCreateInfo vi = { VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO };
    vi.vertexBindingDescriptionCount = 1; vi.pVertexBindingDescriptions = &vbind;
    vi.vertexAttributeDescriptionCount = 1; vi.pVertexAttributeDescriptions = &vattr;
    VkPipelineInputAssemblyStateCreateInfo ia = { VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO };
    ia.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
    VkViewport vp = {0, 0, W, H, 0, 1};
    VkRect2D sc = {{0, 0}, {W, H}};
    VkPipelineViewportStateCreateInfo vps = { VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO };
    vps.viewportCount = 1; vps.pViewports = &vp; vps.scissorCount = 1; vps.pScissors = &sc;
    VkPipelineRasterizationStateCreateInfo rs = { VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO };
    rs.polygonMode = VK_POLYGON_MODE_FILL; rs.cullMode = VK_CULL_MODE_NONE; rs.frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE; rs.lineWidth = 1;
    VkPipelineMultisampleStateCreateInfo ms = { VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO };
    ms.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;
    VkPipelineColorBlendAttachmentState cba = {0};
    cba.colorWriteMask = VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT | VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT;
    VkPipelineColorBlendStateCreateInfo cb = { VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO };
    cb.attachmentCount = 1; cb.pAttachments = &cba;
    VkGraphicsPipelineCreateInfo gpci = { VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO };
    gpci.stageCount = b.nstage; gpci.pStages = ss;
    gpci.pVertexInputState = &vi; gpci.pInputAssemblyState = &ia; gpci.pViewportState = &vps;
    gpci.pRasterizationState = &rs; gpci.pMultisampleState = &ms; gpci.pColorBlendState = &cb;
    gpci.layout = playout; gpci.renderPass = pass; gpci.subpass = 0;
    VkPipeline pipe;
    CHECK(vkCreateGraphicsPipelines(d.device, VK_NULL_HANDLE, 1, &gpci, NULL, &pipe));
    printf("pipeline: created (stages=%u, bindings=%u)\n", b.nstage, b.nbind);

    uint32_t ubo_count = 0;
    for (uint32_t i = 0; i < b.nbind; i++) if (b.b[i].kind == 1) ubo_count++;
    VkDescriptorPoolSize ps[2] = { {VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, ubo_count}, {VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1} };
    VkDescriptorPoolCreateInfo dpci = { VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO };
    dpci.maxSets = 4; dpci.poolSizeCount = has_tex ? 2 : 1; dpci.pPoolSizes = ps;
    VkDescriptorPool dp; CHECK(vkCreateDescriptorPool(d.device, &dpci, NULL, &dp));
    VkDescriptorSetAllocateInfo dsai = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO };
    dsai.descriptorPool = dp; dsai.descriptorSetCount = 4; dsai.pSetLayouts = setl;
    VkDescriptorSet sets[4]; CHECK(vkAllocateDescriptorSets(d.device, &dsai, sets));
    for (uint32_t i = 0; i < b.nbind; i++) {
        if (b.b[i].kind != 1) continue;
        VkDeviceSize size = b.b[i].binding == 0 ? 2608 : 256;   // binding 0 = support；其余按 guest UBO/C1
        VkBufferCreateInfo bci = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO };
        bci.size = size; bci.usage = VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT;
        VkBuffer ub; CHECK(vkCreateBuffer(d.device, &bci, NULL, &ub));
        VkMemoryRequirements bumr; vkGetBufferMemoryRequirements(d.device, ub, &bumr);
        VkMemoryAllocateInfo bumai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO };
        bumai.allocationSize = bumr.size; bumai.memoryTypeIndex = mem_type(&d, bumr.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        VkDeviceMemory ubm; CHECK(vkAllocateMemory(d.device, &bumai, NULL, &ubm));
        CHECK(vkBindBufferMemory(d.device, ub, ubm, 0));
        void *up; CHECK(vkMapMemory(d.device, ubm, 0, size, 0, &up));
        memset(up, 0, (size_t)size);
        if (b.b[i].binding != 0) { ((float *)up)[0] = 0.0f; ((float *)up)[1] = 1.0f; }   // 给 c2ubo 一个可核的颜色
        vkUnmapMemory(d.device, ubm);
        VkDescriptorBufferInfo dbi = { ub, 0, size };
        VkWriteDescriptorSet w = { VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET };
        w.dstSet = sets[b.b[i].set]; w.dstBinding = b.b[i].binding; w.descriptorCount = 1;
        w.descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER; w.pBufferInfo = &dbi;
        vkUpdateDescriptorSets(d.device, 1, &w, 0, NULL);
    }

    VkSampler tsamp = VK_NULL_HANDLE;
    struct nvn_vk_tex *ttex = NULL;
    if (has_tex) {
        tw = tex_data ? tex_w : 1; th = tex_data ? tex_h : 1;
        uint8_t fallback[4] = {0, 255, 0, 255};
        ttex = nvn_vk_texcache_get(&cache, 0x1000, 1, tex_data ? tex_fmt : 0x25, tw, th,
                                   tex_data ? tex_data : fallback, tex_data ? tex_bytes : 4);
        if (!ttex) { printf("FAIL texture cache create (nvn=0x%x)\n", tex_data ? tex_fmt : 0x25); return 1; }
        VkSamplerCreateInfo sci = { VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO };
        sci.magFilter = VK_FILTER_NEAREST; sci.minFilter = VK_FILTER_NEAREST;
        sci.addressModeU = sci.addressModeV = sci.addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        sci.maxLod = 0;
        CHECK(vkCreateSampler(d.device, &sci, NULL, &tsamp));
        VkDescriptorImageInfo dii = { tsamp, ttex->view, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL };
        VkWriteDescriptorSet w2 = { VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET };
        w2.dstSet = sets[tex_set]; w2.dstBinding = tex_binding; w2.descriptorCount = 1;
        w2.descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER; w2.pImageInfo = &dii;
        vkUpdateDescriptorSets(d.device, 1, &w2, 0, NULL);
    }

    // 全屏三角形（c2vspos 的 VS 从 location 0 读 vec4 位置）
    const float verts[3][4] = { {-1, -1, 0, 1}, {3, -1, 0, 1}, {-1, 3, 0, 1} };
    VkBufferCreateInfo vbci = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO };
    vbci.size = sizeof verts; vbci.usage = VK_BUFFER_USAGE_VERTEX_BUFFER_BIT;
    VkBuffer vb; CHECK(vkCreateBuffer(d.device, &vbci, NULL, &vb));
    VkMemoryRequirements vmr; vkGetBufferMemoryRequirements(d.device, vb, &vmr);
    VkMemoryAllocateInfo vmai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO };
    vmai.allocationSize = vmr.size; vmai.memoryTypeIndex = mem_type(&d, vmr.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    VkDeviceMemory vbm; CHECK(vkAllocateMemory(d.device, &vmai, NULL, &vbm));
    CHECK(vkBindBufferMemory(d.device, vb, vbm, 0));
    void *vmap; CHECK(vkMapMemory(d.device, vbm, 0, sizeof verts, 0, &vmap)); memcpy(vmap, verts, sizeof verts); vkUnmapMemory(d.device, vbm);

    const VkDeviceSize bytes = (VkDeviceSize)W * H * 4;
    VkBufferCreateInfo rbci = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO };
    rbci.size = bytes; rbci.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT;
    VkBuffer rb; CHECK(vkCreateBuffer(d.device, &rbci, NULL, &rb));
    VkMemoryRequirements rmr; vkGetBufferMemoryRequirements(d.device, rb, &rmr);
    VkMemoryAllocateInfo rmai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO };
    rmai.allocationSize = rmr.size; rmai.memoryTypeIndex = mem_type(&d, rmr.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    VkDeviceMemory rbm; CHECK(vkAllocateMemory(d.device, &rmai, NULL, &rbm));
    CHECK(vkBindBufferMemory(d.device, rb, rbm, 0));

    VkCommandBufferAllocateInfo cbai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO };
    cbai.commandPool = d.command_pool; cbai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY; cbai.commandBufferCount = 1;
    VkCommandBuffer cmd; CHECK(vkAllocateCommandBuffers(d.device, &cbai, &cmd));
    VkCommandBufferBeginInfo cbbi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
    CHECK(vkBeginCommandBuffer(cmd, &cbbi));
    VkClearValue clear = {{{0.0f, 0.0f, 0.0f, 1.0f}}};
    VkRenderPassBeginInfo rpbi = { VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO };
    rpbi.renderPass = pass; rpbi.framebuffer = fb; rpbi.renderArea = (VkRect2D){{0,0},{W,H}}; rpbi.clearValueCount = 1; rpbi.pClearValues = &clear;
    vkCmdBeginRenderPass(cmd, &rpbi, VK_SUBPASS_CONTENTS_INLINE);
    vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, pipe);
    vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, playout, 0, 4, sets, 0, NULL);
    vkCmdBindVertexBuffers(cmd, 0, 1, &vb, &(VkDeviceSize){0});
    vkCmdDraw(cmd, 3, 1, 0, 0);
    vkCmdEndRenderPass(cmd);
    VkBufferImageCopy bic = {0};
    bic.imageSubresource = (VkImageSubresourceLayers){VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1};
    bic.imageExtent = (VkExtent3D){W, H, 1};
    vkCmdCopyImageToBuffer(cmd, img, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, rb, 1, &bic);
    CHECK(vkEndCommandBuffer(cmd));

    VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO };
    si.commandBufferCount = 1; si.pCommandBuffers = &cmd;
    VkFenceCreateInfo fci = { VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
    VkFence fence; CHECK(vkCreateFence(d.device, &fci, NULL, &fence));
    CHECK(vkQueueSubmit(d.queue, 1, &si, fence));
    CHECK(vkWaitForFences(d.device, 1, &fence, VK_TRUE, 5000000000ull));

    void *pixels; CHECK(vkMapMemory(d.device, rbm, 0, bytes, 0, &pixels));
    const uint8_t *px = pixels; uint32_t nonzero = 0;
    for (uint32_t i = 0; i < W * H; i++) if (px[i*4] || px[i*4+1] || px[i*4+2]) nonzero++;
    uint32_t cx = (H/2 * W + W/2) * 4;
    printf("draw: nonzero=%u/%u center=%u,%u,%u,%u\n", nonzero, W*H, px[cx], px[cx+1], px[cx+2], px[cx+3]);
    vkUnmapMemory(d.device, rbm);
    printf("nvn-vk-be: %s\n", nonzero ? "ok" : "FAIL: empty frame");
    nvn_vk_texcache_destroy(&cache);
    s2a_vk_device_destroy(&d, 0);
    return nonzero ? 0 : 1;
}
