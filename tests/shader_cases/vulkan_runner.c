// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Host-only test runner adapted from the repository vk_micro_test.c.
// C3：native Vulkan 真 GPU 微例（clear / signed clear / draw / compute / copy / readback）。
// 设备与命令都走生产 vk_device.c；shader 由 glslc 在主机生成后随探针推入设备。
// 每个结果与手算值独立比较；不把“提交成功/管线创建”当画面通过。
#include "../../android/native/direct/vk_device.h"

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

#define CHECK(cond, case_name, detail) do { \
    if (!(cond)) { printf("FAIL %s: %s\n", case_name, detail); failures++; } \
} while (0)

static int failures;

static VkDeviceMemory alloc_memory(struct s2a_vk_device *d, VkMemoryRequirements req,
                                   VkMemoryPropertyFlags want) {
    VkMemoryAllocateInfo info = {0};
    info.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    info.allocationSize = req.size;
    info.memoryTypeIndex = s2a_vk_memory_type(d, req.memoryTypeBits, want, NULL);
    if (info.memoryTypeIndex == UINT32_MAX) return VK_NULL_HANDLE;
    VkDeviceMemory memory = VK_NULL_HANDLE;
    if (vkAllocateMemory(d->device, &info, NULL, &memory) != VK_SUCCESS) return VK_NULL_HANDLE;
    return memory;
}

static VkBuffer create_buffer(struct s2a_vk_device *d, VkDeviceSize size, VkBufferUsageFlags usage,
                              VkMemoryPropertyFlags want, VkDeviceMemory *memory, void **mapped) {
    VkBufferCreateInfo info = {0};
    info.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
    info.size = size;
    info.usage = usage;
    info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    VkBuffer buffer = VK_NULL_HANDLE;
    if (vkCreateBuffer(d->device, &info, NULL, &buffer) != VK_SUCCESS) return VK_NULL_HANDLE;
    VkMemoryRequirements req;
    vkGetBufferMemoryRequirements(d->device, buffer, &req);
    *memory = alloc_memory(d, req, want);
    if (!*memory || vkBindBufferMemory(d->device, buffer, *memory, 0) != VK_SUCCESS) return VK_NULL_HANDLE;
    if (mapped) {
        *mapped = NULL;
        if (vkMapMemory(d->device, *memory, 0, VK_WHOLE_SIZE, 0, mapped) != VK_SUCCESS) return VK_NULL_HANDLE;
    }
    return buffer;
}

static VkImage create_image(struct s2a_vk_device *d, uint32_t w, uint32_t h, VkFormat format,
                            VkImageUsageFlags usage, VkDeviceMemory *memory) {
    VkImageCreateInfo info = {0};
    info.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    info.imageType = VK_IMAGE_TYPE_2D;
    info.format = format;
    info.extent.width = w;
    info.extent.height = h;
    info.extent.depth = 1;
    info.mipLevels = 1;
    info.arrayLayers = 1;
    info.samples = VK_SAMPLE_COUNT_1_BIT;
    info.tiling = VK_IMAGE_TILING_OPTIMAL;
    info.usage = usage;
    info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    info.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    VkImage image = VK_NULL_HANDLE;
    if (vkCreateImage(d->device, &info, NULL, &image) != VK_SUCCESS) return VK_NULL_HANDLE;
    VkMemoryRequirements req;
    vkGetImageMemoryRequirements(d->device, image, &req);
    *memory = alloc_memory(d, req, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    if (!*memory || vkBindImageMemory(d->device, image, *memory, 0) != VK_SUCCESS) return VK_NULL_HANDLE;
    return image;
}

static VkCommandBuffer one_shot(struct s2a_vk_device *d) {
    VkCommandBufferAllocateInfo info = {0};
    info.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    info.commandPool = d->command_pool;
    info.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    info.commandBufferCount = 1;
    VkCommandBuffer cmd = VK_NULL_HANDLE;
    if (vkAllocateCommandBuffers(d->device, &info, &cmd) != VK_SUCCESS) return VK_NULL_HANDLE;
    VkCommandBufferBeginInfo begin = {0};
    begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    if (vkBeginCommandBuffer(cmd, &begin) != VK_SUCCESS) { vkFreeCommandBuffers(d->device,d->command_pool,1,&cmd); return VK_NULL_HANDLE; }
    return cmd;
}

static int submit_wait(struct s2a_vk_device *d, VkCommandBuffer cmd) {
    if (!cmd || vkEndCommandBuffer(cmd) != VK_SUCCESS) return -1;
    VkFenceCreateInfo info = {0};
    info.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
    VkFence fence = VK_NULL_HANDLE;
    if (vkCreateFence(d->device, &info, NULL, &fence) != VK_SUCCESS) return -1;
    VkSubmitInfo submit = {0};
    submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
    submit.commandBufferCount = 1;
    submit.pCommandBuffers = &cmd;
    if (vkQueueSubmit(d->queue, 1, &submit, fence) != VK_SUCCESS ||
        vkWaitForFences(d->device, 1, &fence, VK_TRUE, UINT64_MAX) != VK_SUCCESS ||
        vkGetFenceStatus(d->device, fence) != VK_SUCCESS) {
        vkDestroyFence(d->device, fence, NULL);
        return -1;
    }
    vkDestroyFence(d->device, fence, NULL);
    vkFreeCommandBuffers(d->device, d->command_pool, 1, &cmd);
    return 0;
}

static VkRenderPass make_render_pass(struct s2a_vk_device *d, VkFormat format) {
    VkAttachmentDescription color = {0};
    color.format = format;
    color.samples = VK_SAMPLE_COUNT_1_BIT;
    color.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
    color.storeOp = VK_ATTACHMENT_STORE_OP_STORE;
    color.stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
    color.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
    color.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    color.finalLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
    VkAttachmentReference ref = {0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
    VkSubpassDescription subpass = {0};
    subpass.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS;
    subpass.colorAttachmentCount = 1;
    subpass.pColorAttachments = &ref;
    VkSubpassDependency deps[2] = {{0}};
    deps[0].srcSubpass = VK_SUBPASS_EXTERNAL;
    deps[0].dstSubpass = 0;
    deps[0].srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    deps[0].dstStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    deps[0].dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
    deps[1].srcSubpass = 0;
    deps[1].dstSubpass = VK_SUBPASS_EXTERNAL;
    deps[1].srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    deps[1].dstStageMask = VK_PIPELINE_STAGE_TRANSFER_BIT;
    deps[1].srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
    deps[1].dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
    VkRenderPassCreateInfo info = {0};
    info.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
    info.attachmentCount = 1;
    info.pAttachments = &color;
    info.subpassCount = 1;
    info.pSubpasses = &subpass;
    info.dependencyCount = 2;
    info.pDependencies = deps;
    VkRenderPass pass = VK_NULL_HANDLE;
    if (vkCreateRenderPass(d->device, &info, NULL, &pass) != VK_SUCCESS) return VK_NULL_HANDLE;
    return pass;
}

static VkShaderModule load_shader(struct s2a_vk_device *d, const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "cannot open shader %s\n", path); return VK_NULL_HANDLE; }
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (size < 20 || size % 4) { fclose(f); return VK_NULL_HANDLE; }
    uint32_t *data = malloc((size_t)size);
    if (!data || fread(data, 1, (size_t)size, f) != (size_t)size) { free(data); fclose(f); return VK_NULL_HANDLE; }
    fclose(f);
    if (data[0] != 0x07230203 || data[1] != 0x00010300) { free(data); return VK_NULL_HANDLE; }
    VkShaderModuleCreateInfo info = {0};
    info.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
    info.codeSize = (size_t)size;
    info.pCode = data;
    VkShaderModule module = VK_NULL_HANDLE;
    VkResult result = vkCreateShaderModule(d->device, &info, NULL, &module);
    free(data);
    return result == VK_SUCCESS ? module : VK_NULL_HANDLE;
}

static VkPipeline make_graphics_pipeline(struct s2a_vk_device *d, VkRenderPass pass, VkPipelineLayout layout,
                                         const char *vert, const char *frag) {
    VkShaderModule vs = load_shader(d, vert), fs = load_shader(d, frag);
    if (!vs || !fs) return VK_NULL_HANDLE;
    VkPipelineShaderStageCreateInfo stages[2] = {{0}};
    stages[0].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[0].stage = VK_SHADER_STAGE_VERTEX_BIT;
    stages[0].module = vs; stages[0].pName = "main";
    stages[1].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT;
    stages[1].module = fs; stages[1].pName = "main";
    VkPipelineVertexInputStateCreateInfo vertex = {0};
    vertex.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
    VkPipelineInputAssemblyStateCreateInfo assembly = {0};
    assembly.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
    assembly.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
    VkViewport viewport = {0, 0, 64, 64, 0, 1};
    VkRect2D scissor = {{0, 0}, {64, 64}};
    VkPipelineViewportStateCreateInfo vp = {0};
    vp.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
    vp.viewportCount = 1; vp.pViewports = &viewport;
    vp.scissorCount = 1; vp.pScissors = &scissor;
    VkPipelineRasterizationStateCreateInfo raster = {0};
    raster.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
    raster.polygonMode = VK_POLYGON_MODE_FILL;
    raster.cullMode = VK_CULL_MODE_NONE;
    raster.frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE;
    raster.lineWidth = 1;
    VkPipelineMultisampleStateCreateInfo ms = {0};
    ms.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
    ms.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;
    VkPipelineColorBlendAttachmentState blend = {0};
    blend.colorWriteMask = VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT |
                           VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT;
    VkPipelineColorBlendStateCreateInfo cb = {0};
    cb.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
    cb.attachmentCount = 1; cb.pAttachments = &blend;
    VkGraphicsPipelineCreateInfo info = {0};
    info.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
    info.stageCount = 2; info.pStages = stages;
    info.pVertexInputState = &vertex;
    info.pInputAssemblyState = &assembly;
    info.pViewportState = &vp;
    info.pRasterizationState = &raster;
    info.pMultisampleState = &ms;
    info.pColorBlendState = &cb;
    info.layout = layout;
    info.renderPass = pass;
    VkPipeline pipeline = VK_NULL_HANDLE;
    if (vkCreateGraphicsPipelines(d->device, VK_NULL_HANDLE, 1, &info, NULL, &pipeline) != VK_SUCCESS)
        pipeline = VK_NULL_HANDLE;
    vkDestroyShaderModule(d->device, vs, NULL);
    vkDestroyShaderModule(d->device, fs, NULL);
    return pipeline;
}


static const char *output_path;
static int draw_case(struct s2a_vk_device *d, const char *vert, const char *frag) {
    const char *name = "draw-gradient";
    VkImage image = VK_NULL_HANDLE; VkDeviceMemory image_memory = VK_NULL_HANDLE;
    VkBuffer readback = VK_NULL_HANDLE; VkDeviceMemory readback_memory = VK_NULL_HANDLE;
    void *mapped = NULL;
    VkRenderPass pass = make_render_pass(d, VK_FORMAT_R8G8B8A8_UNORM);
    image = create_image(d, 64, 64, VK_FORMAT_R8G8B8A8_UNORM,
                         VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT, &image_memory);
    readback = create_buffer(d, 64 * 64 * 4, VK_BUFFER_USAGE_TRANSFER_DST_BIT,
                             VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                             &readback_memory, &mapped);
    if (!pass || !image || !readback) { failures++; printf("FAIL %s: resource creation\n", name); return -1; }
    VkPipelineLayoutCreateInfo layout_info = {0};
    layout_info.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    VkPipelineLayout layout = VK_NULL_HANDLE;
    vkCreatePipelineLayout(d->device, &layout_info, NULL, &layout);
    VkPipeline pipeline = make_graphics_pipeline(d, pass, layout, vert, frag);
    VkImageViewCreateInfo view_info = {0};
    view_info.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    view_info.image = image; view_info.viewType = VK_IMAGE_VIEW_TYPE_2D; view_info.format = VK_FORMAT_R8G8B8A8_UNORM;
    view_info.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    view_info.subresourceRange.levelCount = 1; view_info.subresourceRange.layerCount = 1;
    VkImageView view = VK_NULL_HANDLE;
    vkCreateImageView(d->device, &view_info, NULL, &view);
    VkFramebufferCreateInfo fb_info = {0};
    fb_info.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
    fb_info.renderPass = pass; fb_info.attachmentCount = 1; fb_info.pAttachments = &view;
    fb_info.width = 64; fb_info.height = 64; fb_info.layers = 1;
    VkFramebuffer framebuffer = VK_NULL_HANDLE;
    vkCreateFramebuffer(d->device, &fb_info, NULL, &framebuffer);
    if (!pipeline || !view || !framebuffer) { failures++; printf("FAIL %s: pipeline creation\n", name); return -1; }
    VkCommandBuffer cmd = one_shot(d);
    if (!cmd) { failures++; return -1; }
    VkClearValue clear = {0};
    clear.color = (VkClearColorValue){{0, 0, 0, 1}};
    VkRenderPassBeginInfo begin = {0};
    begin.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
    begin.renderPass = pass; begin.framebuffer = framebuffer;
    begin.renderArea.extent.width = 64; begin.renderArea.extent.height = 64;
    begin.clearValueCount = 1; begin.pClearValues = &clear;
    vkCmdBeginRenderPass(cmd, &begin, VK_SUBPASS_CONTENTS_INLINE);
    vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
    vkCmdDraw(cmd, 3, 1, 0, 0);
    vkCmdEndRenderPass(cmd);
    VkBufferImageCopy region = {0};
    region.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    region.imageSubresource.layerCount = 1;
    region.imageExtent.width = 64; region.imageExtent.height = 64; region.imageExtent.depth = 1;
    vkCmdCopyImageToBuffer(cmd, image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, readback, 1, &region);
    VkBufferMemoryBarrier host_read={0};
    host_read.sType=VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER;
    host_read.srcAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT;
    host_read.dstAccessMask=VK_ACCESS_HOST_READ_BIT;
    host_read.srcQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED;
    host_read.dstQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED;
    host_read.buffer=readback;host_read.offset=0;host_read.size=VK_WHOLE_SIZE;
    vkCmdPipelineBarrier(cmd,VK_PIPELINE_STAGE_TRANSFER_BIT,VK_PIPELINE_STAGE_HOST_BIT,0,0,NULL,1,&host_read,0,NULL);
    int rc = submit_wait(d, cmd);
    if (rc == 0) {
        const uint8_t *center = (const uint8_t *)mapped + (32 * 64 + 32) * 4;
        FILE *out=fopen(output_path,"wb");
        if (!out || fwrite(center,1,4,out)!=4) { failures++; if(out) fclose(out); }
        else fclose(out);
    } else { failures++; printf("FAIL %s: submit/wait\n", name); }
    vkUnmapMemory(d->device, readback_memory);
    vkDestroyFramebuffer(d->device, framebuffer, NULL);
    vkDestroyImageView(d->device, view, NULL);
    vkDestroyPipeline(d->device, pipeline, NULL);
    vkDestroyPipelineLayout(d->device, layout, NULL);
    vkDestroyRenderPass(d->device, pass, NULL);
    vkDestroyBuffer(d->device, readback, NULL); vkFreeMemory(d->device, readback_memory, NULL);
    vkDestroyImage(d->device, image, NULL); vkFreeMemory(d->device, image_memory, NULL);
    return rc;
}


static int compute_case(struct s2a_vk_device *d, const char *path, const char *input_path) {
    const char *name = "compute-ssbo";
    VkDeviceMemory input_memory = VK_NULL_HANDLE;
    void *mapped = NULL;
    VkBuffer buffer = create_buffer(d, 64 * 4, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
                                    VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                                    &input_memory, &mapped);
    if (!buffer) { failures++; printf("FAIL %s: buffer\n", name); return -1; }
    FILE *input=fopen(input_path,"rb");
    if(!input || fread(mapped,1,64*4,input)!=64*4) { if(input) fclose(input); failures++; return -1; }
    fclose(input);
    VkShaderModule module = load_shader(d, path);
    VkDescriptorSetLayoutBinding binding = {0};
    binding.binding = 0; binding.descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
    binding.descriptorCount = 1; binding.stageFlags = VK_SHADER_STAGE_COMPUTE_BIT;
    VkDescriptorSetLayoutCreateInfo set_info = {0};
    set_info.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
    set_info.bindingCount = 1; set_info.pBindings = &binding;
    VkDescriptorSetLayout set_layout = VK_NULL_HANDLE;
    vkCreateDescriptorSetLayout(d->device, &set_info, NULL, &set_layout);
    VkPipelineLayoutCreateInfo layout_info = {0};
    layout_info.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    // Modeled C0 is a zero-filled 64 KiB guest constant buffer: address base = 0.
    // The clamped helper really reads cp_c0 at set0/binding1 (vec4[4096]);
    // the unclamped shader may optimize it away. This is input, not expected output.
    VkDeviceMemory c0_memory=VK_NULL_HANDLE; void *c0_mapped=NULL;
    VkBuffer c0=create_buffer(d,65536,VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
        VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT|VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,&c0_memory,&c0_mapped);
    if (!c0 || d->properties.limits.maxUniformBufferRange < 65536) { failures++; return -1; }
    memset(c0_mapped,0,65536);
    VkDescriptorSetLayoutBinding c0_binding={0};
    c0_binding.binding=1; c0_binding.descriptorType=VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
    c0_binding.descriptorCount=1; c0_binding.stageFlags=VK_SHADER_STAGE_COMPUTE_BIT;
    VkDescriptorSetLayout c0_layout=VK_NULL_HANDLE;
    VkDescriptorSetLayoutCreateInfo c0_info={0}; c0_info.sType=VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
    c0_info.bindingCount=1; c0_info.pBindings=&c0_binding;
    if(vkCreateDescriptorSetLayout(d->device,&c0_info,NULL,&c0_layout)!=VK_SUCCESS) { failures++; return -1; }
    VkDescriptorSetLayout layouts[2]={c0_layout,set_layout};
    layout_info.setLayoutCount = 2; layout_info.pSetLayouts = layouts;
    VkPipelineLayout layout = VK_NULL_HANDLE;
    vkCreatePipelineLayout(d->device, &layout_info, NULL, &layout);
    VkComputePipelineCreateInfo pipe_info = {0};
    pipe_info.sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO;
    pipe_info.stage.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    pipe_info.stage.stage = VK_SHADER_STAGE_COMPUTE_BIT;
    pipe_info.stage.module = module; pipe_info.stage.pName = "main";
    pipe_info.layout = layout;
    VkPipeline pipeline = VK_NULL_HANDLE;
    VkResult pipe_result = vkCreateComputePipelines(d->device, VK_NULL_HANDLE, 1, &pipe_info, NULL, &pipeline);
    VkDescriptorPoolSize pool_sizes[2] = {{VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,1},{VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,1}};
    VkDescriptorPoolCreateInfo pool_info = {0};
    pool_info.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
    pool_info.maxSets = 2; pool_info.poolSizeCount = 2; pool_info.pPoolSizes = pool_sizes;
    VkDescriptorPool pool = VK_NULL_HANDLE;
    vkCreateDescriptorPool(d->device, &pool_info, NULL, &pool);
    VkDescriptorSetAllocateInfo alloc = {0};
    alloc.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
    alloc.descriptorPool = pool; alloc.descriptorSetCount = 2; alloc.pSetLayouts = layouts;
    VkDescriptorSet sets[2] = {VK_NULL_HANDLE,VK_NULL_HANDLE};
    vkAllocateDescriptorSets(d->device, &alloc, sets);
    VkDescriptorBufferInfo buffer_info = {buffer, 0, VK_WHOLE_SIZE};
    VkWriteDescriptorSet write = {0};
    write.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    write.dstSet = sets[1]; write.dstBinding = 0; write.descriptorCount = 1;
    write.descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
    write.pBufferInfo = &buffer_info;
    if (!module || !set_layout || !layout || pipe_result != VK_SUCCESS || !pool || !sets[0] || !sets[1]) {
        failures++; printf("FAIL %s: pipeline/descriptor creation\n", name); return -1;
    }
    VkDescriptorBufferInfo c0_buffer_info={c0,0,65536};
    VkWriteDescriptorSet c0_write={0}; c0_write.sType=VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    c0_write.dstSet=sets[0]; c0_write.dstBinding=1; c0_write.descriptorCount=1;
    c0_write.descriptorType=VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER; c0_write.pBufferInfo=&c0_buffer_info;
    VkWriteDescriptorSet writes[2]={c0_write,write};
    vkUpdateDescriptorSets(d->device, 2, writes, 0, NULL);
    VkCommandBuffer cmd = one_shot(d);
    if (!cmd) { failures++; return -1; }
    vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, pipeline);
    vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, layout, 0, 2, sets, 0, NULL);
    vkCmdDispatch(cmd, 1, 1, 1);
    VkBufferMemoryBarrier barrier = {0};
    barrier.sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER;
    barrier.srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT;
    barrier.dstAccessMask = VK_ACCESS_HOST_READ_BIT;
    barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barrier.buffer = buffer; barrier.offset = 0; barrier.size = VK_WHOLE_SIZE;
    vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_HOST_BIT,
                         0, 0, NULL, 1, &barrier, 0, NULL);
    int rc = submit_wait(d, cmd);
    if (rc == 0) {
        FILE *out=fopen(output_path,"wb");
        if(!out || fwrite(mapped,1,64*4,out)!=64*4) { failures++; if(out) fclose(out); }
        else fclose(out);
    } else { failures++; printf("FAIL %s: submit/wait\n", name); }
    vkUnmapMemory(d->device, input_memory);
    vkDestroyDescriptorPool(d->device, pool, NULL);
    vkDestroyPipeline(d->device, pipeline, NULL);
    vkDestroyPipelineLayout(d->device, layout, NULL);
    vkDestroyDescriptorSetLayout(d->device, set_layout, NULL);
    vkDestroyDescriptorSetLayout(d->device, c0_layout, NULL);
    vkUnmapMemory(d->device,c0_memory);
    vkDestroyBuffer(d->device,c0,NULL); vkFreeMemory(d->device,c0_memory,NULL);
    vkDestroyShaderModule(d->device, module, NULL);
    vkDestroyBuffer(d->device, buffer, NULL); vkFreeMemory(d->device, input_memory, NULL);
    return rc;
}

int main(int argc,char **argv) {
    if(argc!=5) return 2;
    output_path=argv[4];
    struct s2a_vk_device device; char why[192]={0};
    if(s2a_vk_device_create(&device,why,sizeof why)) { fprintf(stderr,"%s\n",why); return 1; }
    if(device.properties.deviceType != VK_PHYSICAL_DEVICE_TYPE_CPU || !strstr(device.properties.deviceName,"llvmpipe")) {
        fprintf(stderr,"Requires lavapipe, got %s\n",device.properties.deviceName); return 2;
    }
    if(!strcmp(argv[1],"fragment")) draw_case(&device,argv[2],argv[3]);
    else if(!strcmp(argv[1],"compute")) compute_case(&device,argv[2],argv[3]);
    else failures++;
    s2a_vk_device_destroy(&device,0);
    return failures?1:0;
}
