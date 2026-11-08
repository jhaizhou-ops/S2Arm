#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "nvn_vk_pipeline.h"

struct blob {
    uint32_t nstage, nbind;
    struct { uint32_t stage; const uint8_t *spv; uint32_t bytes, stride; } st[4];
    struct { uint32_t set, binding, kind, count; } b[16];
    uint8_t *raw;
    size_t raw_len;
};

static uint32_t rd32(const uint8_t *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }

// 布局与 nvn_vk_program_blob.py 一致：magic "NVKP\0" + u32 version/stage_count/binding_count，
// stage_count × {u32 nvn_stage, u32 spirv_bytes, SPIR-V（4 字节对齐）}，binding_count × {set,binding,kind,count}。
static int load_blob(const char *path, struct blob *b, char *why, size_t why_size) {
    FILE *f = fopen(path, "rb");
    if (!f) { if (why) snprintf(why, why_size, "open %s", path); return -1; }
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    uint8_t *p = malloc((size_t)n);
    if (!p || fread(p, 1, (size_t)n, f) != (size_t)n) { fclose(f); free(p); if (why) snprintf(why, why_size, "read %s", path); return -1; }
    fclose(f);
    memset(b, 0, sizeof *b);
    if (n < 16 || memcmp(p, "NVKP", 4)) { free(p); if (why) snprintf(why, why_size, "not NVKP"); return -1; }
    b->raw = p; b->raw_len = (size_t)n;
    if (rd32(p + 4) != 1) { free(p); if (why) snprintf(why, why_size, "NVKP version"); return -1; }
    b->nstage = rd32(p + 8); b->nbind = rd32(p + 12);
    if (b->nstage > 4 || b->nbind > 16) { free(p); if (why) snprintf(why, why_size, "too many stages/bindings"); return -1; }
    size_t at = 16;
    for (uint32_t i = 0; i < b->nstage; i++) {
        if (at + 8 > (size_t)n) { free(p); if (why) snprintf(why, why_size, "stage header truncated"); return -1; }
        b->st[i].stage = rd32(p + at); b->st[i].bytes = rd32(p + at + 4);
        b->st[i].stride = (b->st[i].bytes + 3u) & ~3u;
        b->st[i].spv = p + at + 8;
        if (at + 8 + b->st[i].stride > (size_t)n) { free(p); if (why) snprintf(why, why_size, "SPIR-V truncated"); return -1; }
        at += 8 + b->st[i].stride;
    }
    for (uint32_t i = 0; i < b->nbind; i++) {
        if (at + 16 > (size_t)n) { free(p); if (why) snprintf(why, why_size, "binding header truncated"); return -1; }
        b->b[i].set = rd32(p + at); b->b[i].binding = rd32(p + at + 4);
        b->b[i].kind = rd32(p + at + 8); b->b[i].count = rd32(p + at + 12);
        at += 16;
    }
    return 0;
}
static void free_blob(struct blob *b) { free(b->raw); }

static uint64_t fnv(const uint8_t *p, size_t n) {
    uint64_t h = 1469598103934665603ull;
    for (size_t i = 0; i < n; i++) { h ^= p[i]; h *= 1099511628211ull; }
    return h;
}

static int create(struct nvn_vk_pipeline_cache *c, uint64_t key, VkFormat color, const struct nvn_vk_vertex_layout *vl,
                  struct blob *b, char *why, size_t why_size, int *slot) {
    int s = -1;
    for (int i = 0; i < 16; i++) if (!c->slots[i].valid) { s = i; break; }
    if (s < 0) { if (why) snprintf(why, why_size, "pipeline cache full"); return -1; }
    VkShaderStageFlagBits stg[4];
    for (uint32_t i = 0; i < b->nstage; i++) {
        stg[i] = b->st[i].stage == 0 ? VK_SHADER_STAGE_VERTEX_BIT : b->st[i].stage == 4 ? VK_SHADER_STAGE_FRAGMENT_BIT :
                 b->st[i].stage == 5 ? VK_SHADER_STAGE_COMPUTE_BIT : VK_SHADER_STAGE_GEOMETRY_BIT;
    }
    for (uint32_t i = 0; i < b->nstage; i++) {
        VkShaderModuleCreateInfo sm = { VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO };
        sm.codeSize = b->st[i].bytes;
        sm.pCode = (const uint32_t *)b->st[i].spv;
        if (vkCreateShaderModule(c->d->device, &sm, NULL, &c->slots[s].mod[i]) != VK_SUCCESS) { if (why) snprintf(why, why_size, "shader module %u", i); return -1; }
        c->slots[s].nmod++;
    }
    for (int set = 0; set < 4; set++) {
        VkDescriptorSetLayoutBinding mine[16]; uint32_t n = 0;
        for (uint32_t i = 0; i < b->nbind; i++) {
            if ((int)b->b[i].set != set) continue;
            memset(&mine[n], 0, sizeof mine[n]);
            mine[n].binding = b->b[i].binding;
            mine[n].descriptorType = b->b[i].kind == 1 ? VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER : VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
            mine[n].descriptorCount = 1;
            mine[n].stageFlags = VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT;
            n++;
        }
        VkDescriptorSetLayoutCreateInfo l = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO };
        l.bindingCount = n; l.pBindings = n ? mine : NULL;
        if (vkCreateDescriptorSetLayout(c->d->device, &l, NULL, &c->slots[s].setl[set]) != VK_SUCCESS) { if (why) snprintf(why, why_size, "set layout %d", set); return -1; }
    }
    VkPipelineLayoutCreateInfo pl = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO };
    pl.setLayoutCount = 4; pl.pSetLayouts = c->slots[s].setl;
    if (vkCreatePipelineLayout(c->d->device, &pl, NULL, &c->slots[s].playout) != VK_SUCCESS) { if (why) snprintf(why, why_size, "pipeline layout"); return -1; }
    VkAttachmentDescription at = {0};
    at.format = color; at.samples = VK_SAMPLE_COUNT_1_BIT; at.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR; at.storeOp = VK_ATTACHMENT_STORE_OP_STORE;
    at.stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE; at.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
    at.initialLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL; at.finalLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
    VkAttachmentReference ar = {0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
    VkSubpassDescription sub = {0}; sub.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS; sub.colorAttachmentCount = 1; sub.pColorAttachments = &ar;
    VkRenderPassCreateInfo rp = { VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO };
    rp.attachmentCount = 1; rp.pAttachments = &at; rp.subpassCount = 1; rp.pSubpasses = &sub;
    if (vkCreateRenderPass(c->d->device, &rp, NULL, &c->slots[s].pass) != VK_SUCCESS) { if (why) snprintf(why, why_size, "render pass"); return -1; }
    VkPipelineShaderStageCreateInfo ss[4]; memset(ss, 0, sizeof ss);
    for (uint32_t i = 0; i < b->nstage; i++) { ss[i].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO; ss[i].stage = stg[i]; ss[i].module = c->slots[s].mod[i]; ss[i].pName = "main"; }
    VkPipelineVertexInputStateCreateInfo vi = { VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO };
    if (vl) { vi.vertexBindingDescriptionCount = vl->binding_count; vi.pVertexBindingDescriptions = vl->bindings;
              vi.vertexAttributeDescriptionCount = vl->attribute_count; vi.pVertexAttributeDescriptions = vl->attributes; }
    VkPipelineInputAssemblyStateCreateInfo ia = { VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO }; ia.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
    VkPipelineViewportStateCreateInfo vp = { VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO }; vp.viewportCount = 1; vp.scissorCount = 1;
    VkPipelineRasterizationStateCreateInfo rs = { VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO }; rs.polygonMode = VK_POLYGON_MODE_FILL; rs.cullMode = VK_CULL_MODE_NONE; rs.frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE; rs.lineWidth = 1;
    VkPipelineMultisampleStateCreateInfo ms = { VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO }; ms.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;
    VkPipelineColorBlendAttachmentState cb = {0}; cb.colorWriteMask = 0xf;
    VkPipelineColorBlendStateCreateInfo cbs = { VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO }; cbs.attachmentCount = 1; cbs.pAttachments = &cb;
    VkDynamicState dyn[2] = { VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR };
    VkPipelineDynamicStateCreateInfo ds = { VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO }; ds.dynamicStateCount = 2; ds.pDynamicStates = dyn;
    VkGraphicsPipelineCreateInfo gp = { VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO };
    gp.stageCount = b->nstage; gp.pStages = ss; gp.pVertexInputState = &vi; gp.pInputAssemblyState = &ia;
    gp.pViewportState = &vp; gp.pRasterizationState = &rs; gp.pMultisampleState = &ms; gp.pColorBlendState = &cbs; gp.pDynamicState = &ds;
    gp.layout = c->slots[s].playout; gp.renderPass = c->slots[s].pass;
    if (vkCreateGraphicsPipelines(c->d->device, VK_NULL_HANDLE, 1, &gp, NULL, &c->slots[s].pipe) != VK_SUCCESS) { if (why) snprintf(why, why_size, "pipeline create"); return -1; }
    VkDescriptorPoolSize ps[2]; uint32_t nps = 0, nubo = 0, ntex = 0;
    for (uint32_t i = 0; i < b->nbind; i++) { if (b->b[i].kind == 1) nubo++; else ntex++; }
    if (nubo) { ps[nps].type = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER; ps[nps++].descriptorCount = nubo * 4; }
    if (ntex) { ps[nps].type = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER; ps[nps++].descriptorCount = ntex * 4; }
    VkDescriptorPoolCreateInfo pci = { VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO };
    pci.maxSets = 4; pci.poolSizeCount = nps; pci.pPoolSizes = ps;
    if (vkCreateDescriptorPool(c->d->device, &pci, NULL, &c->slots[s].pool) != VK_SUCCESS) { if (why) snprintf(why, why_size, "descriptor pool"); return -1; }
    VkDescriptorSetAllocateInfo ai = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO };
    ai.descriptorPool = c->slots[s].pool; ai.descriptorSetCount = 4; ai.pSetLayouts = c->slots[s].setl;
    if (vkAllocateDescriptorSets(c->d->device, &ai, c->slots[s].sets) != VK_SUCCESS) { if (why) snprintf(why, why_size, "descriptor sets"); return -1; }
    c->slots[s].key = key; c->slots[s].color = color; c->slots[s].valid = 1; c->created++; *slot = s;
    return 0;
}

void nvn_vk_pipeline_init(struct nvn_vk_pipeline_cache *c, struct s2a_vk_device *d) { memset(c, 0, sizeof *c); c->d = d; }
void nvn_vk_pipeline_destroy(struct nvn_vk_pipeline_cache *c) {
    for (int i = 0; i < 16; i++) if (c->slots[i].valid) {
        vkDestroyPipeline(c->d->device, c->slots[i].pipe, NULL);
        if (c->slots[i].pool) vkDestroyDescriptorPool(c->d->device, c->slots[i].pool, NULL);
        vkDestroyRenderPass(c->d->device, c->slots[i].pass, NULL);
        vkDestroyPipelineLayout(c->d->device, c->slots[i].playout, NULL);
        for (uint32_t k = 0; k < c->slots[i].nmod; k++) vkDestroyShaderModule(c->d->device, c->slots[i].mod[k], NULL);
        for (int s = 0; s < 4; s++) vkDestroyDescriptorSetLayout(c->d->device, c->slots[i].setl[s], NULL);
        c->slots[i].valid = 0;
    }
}

int nvn_vk_pipeline_sets(struct nvn_vk_pipeline_cache *c, VkPipeline pipe, VkDescriptorSet sets[4]) {
    for (int i = 0; i < 16; i++) if (c->slots[i].valid && c->slots[i].pipe == pipe) {
        for (int s = 0; s < 4; s++) sets[s] = c->slots[i].sets[s];
        return 0;
    }
    return -1;
}

static int find_slot(struct nvn_vk_pipeline_cache *c, VkPipeline pipe) {
    for (int i = 0; i < 16; i++) if (c->slots[i].valid && c->slots[i].pipe == pipe) return i;
    return -1;
}

int nvn_vk_pipeline_update_ubo(struct nvn_vk_pipeline_cache *c, VkPipeline pipe, uint32_t set, uint32_t binding,
                               VkBuffer buffer, VkDeviceSize offset, VkDeviceSize range) {
    int s = find_slot(c, pipe);
    if (s < 0 || set > 3) return -1;
    VkDescriptorBufferInfo bi = { buffer, offset, range };
    VkWriteDescriptorSet w = { VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET };
    w.dstSet = c->slots[s].sets[set]; w.dstBinding = binding; w.descriptorCount = 1;
    w.descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER; w.pBufferInfo = &bi;
    vkUpdateDescriptorSets(c->d->device, 1, &w, 0, NULL);
    return 0;
}

int nvn_vk_pipeline_update_tex(struct nvn_vk_pipeline_cache *c, VkPipeline pipe, uint32_t set, uint32_t binding,
                               VkImageView view, VkSampler sampler) {
    int s = find_slot(c, pipe);
    if (s < 0 || set > 3) return -1;
    VkDescriptorImageInfo ii = { sampler, view, VK_IMAGE_LAYOUT_GENERAL };
    VkWriteDescriptorSet w = { VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET };
    w.dstSet = c->slots[s].sets[set]; w.dstBinding = binding; w.descriptorCount = 1;
    w.descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER; w.pImageInfo = &ii;
    vkUpdateDescriptorSets(c->d->device, 1, &w, 0, NULL);
    return 0;
}

VkRenderPass nvn_vk_pipeline_render_pass(struct nvn_vk_pipeline_cache *c, VkPipeline pipe) {
    for (int i = 0; i < 16; i++) if (c->slots[i].valid && c->slots[i].pipe == pipe) return c->slots[i].pass;
    return VK_NULL_HANDLE;
}

int nvn_vk_pipeline_record(struct nvn_vk_pipeline_cache *c, VkPipeline pipe, VkCommandBuffer cmd,
                           VkImageView view, uint32_t w, uint32_t h, VkBuffer vb, VkBuffer ubo, VkDeviceSize ubo_size,
                           VkFramebuffer *fb_out) {
    int slot = find_slot(c, pipe);
    if (slot < 0 || !cmd || !view) return -1;
    if (ubo) nvn_vk_pipeline_update_ubo(c, pipe, 0, 0, ubo, 0, ubo_size);
    VkFramebufferCreateInfo fci = { VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO };
    fci.renderPass = c->slots[slot].pass; fci.attachmentCount = 1; fci.pAttachments = &view;
    fci.width = w; fci.height = h; fci.layers = 1;
    VkFramebuffer fb = VK_NULL_HANDLE;
    if (vkCreateFramebuffer(c->d->device, &fci, NULL, &fb) != VK_SUCCESS) return -1;
    VkClearValue clear = {0};
    VkRenderPassBeginInfo rbi = { VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO };
    rbi.renderPass = c->slots[slot].pass; rbi.framebuffer = fb; rbi.renderArea.extent = (VkExtent2D){w, h};
    rbi.clearValueCount = 1; rbi.pClearValues = &clear;
    vkCmdBeginRenderPass(cmd, &rbi, VK_SUBPASS_CONTENTS_INLINE);
    vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, pipe);
    vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, c->slots[slot].playout, 0, 4, c->slots[slot].sets, 0, NULL);
    VkDeviceSize off = 0;
    if (vb) vkCmdBindVertexBuffers(cmd, 0, 1, &vb, &off);
    VkViewport vpp = {0, 0, (float)w, (float)h, 0, 1};
    vkCmdSetViewport(cmd, 0, 1, &vpp);
    VkRect2D sc = {{0, 0}, {w, h}};
    vkCmdSetScissor(cmd, 0, 1, &sc);
    vkCmdDraw(cmd, 3, 1, 0, 0);
    vkCmdEndRenderPass(cmd);
    if (fb_out) *fb_out = fb; else vkDestroyFramebuffer(c->d->device, fb, NULL);
    return 0;
}

int nvn_vk_pipeline_draw(struct nvn_vk_pipeline_cache *c, VkPipeline pipe, VkImageView view, uint32_t w, uint32_t h,
                         const void *vertices, size_t vertex_bytes, VkBuffer ubo, VkDeviceSize ubo_size) {
    if (!vertices || vertex_bytes < 16) return -1;
    VkBufferCreateInfo bci = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO };
    bci.size = vertex_bytes; bci.usage = VK_BUFFER_USAGE_VERTEX_BUFFER_BIT;
    VkBuffer vb = VK_NULL_HANDLE;
    if (vkCreateBuffer(c->d->device, &bci, NULL, &vb) != VK_SUCCESS) return -1;
    VkMemoryRequirements vmr; vkGetBufferMemoryRequirements(c->d->device, vb, &vmr);
    VkMemoryAllocateInfo vai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO };
    vai.allocationSize = vmr.size;
    vai.memoryTypeIndex = s2a_vk_memory_type(c->d, vmr.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, NULL);
    VkDeviceMemory vmem = VK_NULL_HANDLE;
    if (vkAllocateMemory(c->d->device, &vai, NULL, &vmem) != VK_SUCCESS || vkBindBufferMemory(c->d->device, vb, vmem, 0) != VK_SUCCESS) { vkDestroyBuffer(c->d->device, vb, NULL); return -1; }
    void *vp = NULL;
    if (vkMapMemory(c->d->device, vmem, 0, vertex_bytes, 0, &vp) == VK_SUCCESS) { memcpy(vp, vertices, vertex_bytes); vkUnmapMemory(c->d->device, vmem); }
    VkCommandBufferAllocateInfo cai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO };
    cai.commandPool = c->d->command_pool; cai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY; cai.commandBufferCount = 1;
    VkCommandBuffer cmd = VK_NULL_HANDLE;
    if (vkAllocateCommandBuffers(c->d->device, &cai, &cmd) != VK_SUCCESS) { vkDestroyBuffer(c->d->device, vb, NULL); vkFreeMemory(c->d->device, vmem, NULL); return -1; }
    VkCommandBufferBeginInfo bi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
    bi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    vkBeginCommandBuffer(cmd, &bi);
    VkFramebuffer fb = VK_NULL_HANDLE;
    int rc = nvn_vk_pipeline_record(c, pipe, cmd, view, w, h, vb, ubo, ubo_size, &fb);
    vkEndCommandBuffer(cmd);
    VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO };
    si.commandBufferCount = 1; si.pCommandBuffers = &cmd;
    VkFenceCreateInfo fci2 = { VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
    VkFence fence = VK_NULL_HANDLE;
    vkCreateFence(c->d->device, &fci2, NULL, &fence);
    int ok = rc == 0 && vkQueueSubmit(c->d->queue, 1, &si, fence) == VK_SUCCESS && vkWaitForFences(c->d->device, 1, &fence, VK_TRUE, 2000000000ull) == VK_SUCCESS;
    vkDestroyFence(c->d->device, fence, NULL);
    vkFreeCommandBuffers(c->d->device, c->d->command_pool, 1, &cmd);
    if (fb) vkDestroyFramebuffer(c->d->device, fb, NULL);
    vkDestroyBuffer(c->d->device, vb, NULL);
    vkFreeMemory(c->d->device, vmem, NULL);
    return ok ? 0 : -1;
}

VkPipeline nvn_vk_pipeline_get(struct nvn_vk_pipeline_cache *c, const char *blob_path, VkFormat color,
                               const struct nvn_vk_vertex_layout *vl, char *why, size_t why_size) {
    struct blob b;
    if (load_blob(blob_path, &b, why, why_size)) return VK_NULL_HANDLE;
    uint64_t key = fnv(b.raw, b.raw_len);
    if (vl) key ^= fnv((const uint8_t *)vl->bindings, vl->binding_count * sizeof *vl->bindings) * 0x9e3779b97f4a7c15ull
                    ^ fnv((const uint8_t *)vl->attributes, vl->attribute_count * sizeof *vl->attributes);
    for (int i = 0; i < 16; i++) if (c->slots[i].valid && c->slots[i].key == key && c->slots[i].color == color) { c->reused++; free_blob(&b); return c->slots[i].pipe; }
    int slot = -1;
    if (create(c, key, color, vl, &b, why, why_size, &slot)) { free_blob(&b); return VK_NULL_HANDLE; }
    free_blob(&b);
    return c->slots[slot].pipe;
}
