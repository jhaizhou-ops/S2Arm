// C3：native Vulkan 真 GPU 微例（clear / signed clear / draw / compute / copy / readback）。
// 设备与命令都走生产 vk_device.c；shader 由 glslc 在主机生成后随探针推入设备。
// 每个结果与手算值独立比较；不把“提交成功/管线创建”当画面通过。
#include "../native/direct/vk_device.h"

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
    vkBeginCommandBuffer(cmd, &begin);
    return cmd;
}

static int submit_wait(struct s2a_vk_device *d, VkCommandBuffer cmd) {
    vkEndCommandBuffer(cmd);
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
    if (size <= 0 || size % 4) { fclose(f); return VK_NULL_HANDLE; }
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

static int clear_case(struct s2a_vk_device *d, VkFormat format, VkClearColorValue clear,
                      void (*verify)(const uint8_t *pixels, const char *name), const char *name,
                      const char *label) {
    VkImage image = VK_NULL_HANDLE; VkDeviceMemory image_memory = VK_NULL_HANDLE;
    VkBuffer readback = VK_NULL_HANDLE; VkDeviceMemory readback_memory = VK_NULL_HANDLE;
    void *mapped = NULL;
    VkRenderPass pass = VK_NULL_HANDLE; VkImageView view = VK_NULL_HANDLE; VkFramebuffer framebuffer = VK_NULL_HANDLE;
    image = create_image(d, 64, 64, format, VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
                         &image_memory);
    readback = create_buffer(d, 64 * 64 * 4, VK_BUFFER_USAGE_TRANSFER_DST_BIT,
                             VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                             &readback_memory, &mapped);
    pass = make_render_pass(d, format);
    if (!image || !readback || !pass) { failures++; printf("FAIL %s: resource creation\n", name); return -1; }
    VkImageViewCreateInfo view_info = {0};
    view_info.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    view_info.image = image; view_info.viewType = VK_IMAGE_VIEW_TYPE_2D; view_info.format = format;
    view_info.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    view_info.subresourceRange.levelCount = 1; view_info.subresourceRange.layerCount = 1;
    if (vkCreateImageView(d->device, &view_info, NULL, &view) != VK_SUCCESS) { failures++; return -1; }
    VkFramebufferCreateInfo fb_info = {0};
    fb_info.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
    fb_info.renderPass = pass; fb_info.attachmentCount = 1; fb_info.pAttachments = &view;
    fb_info.width = 64; fb_info.height = 64; fb_info.layers = 1;
    if (vkCreateFramebuffer(d->device, &fb_info, NULL, &framebuffer) != VK_SUCCESS) { failures++; return -1; }
    VkCommandBuffer cmd = one_shot(d);
    VkClearValue clear_value = {0};
    clear_value.color = clear;
    VkRenderPassBeginInfo begin = {0};
    begin.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
    begin.renderPass = pass; begin.framebuffer = framebuffer;
    begin.renderArea.extent.width = 64; begin.renderArea.extent.height = 64;
    begin.clearValueCount = 1; begin.pClearValues = &clear_value;
    vkCmdBeginRenderPass(cmd, &begin, VK_SUBPASS_CONTENTS_INLINE);
    vkCmdEndRenderPass(cmd);
    VkBufferImageCopy region = {0};
    region.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    region.imageSubresource.layerCount = 1;
    region.imageExtent.width = 64; region.imageExtent.height = 64; region.imageExtent.depth = 1;
    vkCmdCopyImageToBuffer(cmd, image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, readback, 1, &region);
    int rc = submit_wait(d, cmd);
    if (rc == 0) {
        verify(mapped, name);
        printf("INFO %s: %s\n", name, label);
    } else { failures++; printf("FAIL %s: submit/wait\n", name); }
    vkUnmapMemory(d->device, readback_memory);
    vkDestroyFramebuffer(d->device, framebuffer, NULL);
    vkDestroyImageView(d->device, view, NULL);
    vkDestroyRenderPass(d->device, pass, NULL);
    vkDestroyBuffer(d->device, readback, NULL);
    vkFreeMemory(d->device, readback_memory, NULL);
    vkDestroyImage(d->device, image, NULL);
    vkFreeMemory(d->device, image_memory, NULL);
    return rc;
}

static void verify_clear_rgba8(const uint8_t *pixels, const char *name) {
    // 0.25/0.5/0.75/1.0 -> 64/128/191/255（四舍五入）。
    const uint8_t expect[4] = {64, 128, 191, 255};
    const uint8_t got[4] = {pixels[0], pixels[1], pixels[2], pixels[3]};
    CHECK(!memcmp(got, expect, 4), name, "clear pixel differs from hand-computed RGBA8 quantisation");
    printf("INFO %s: pixel=%u,%u,%u,%u\n", name, got[0], got[1], got[2], got[3]);
}

static void verify_clear_sint8(const uint8_t *pixels, const char *name) {
    const int8_t expect[4] = {-128, -1, 0, 127};
    const int8_t got[4] = {(int8_t)pixels[0], (int8_t)pixels[1], (int8_t)pixels[2], (int8_t)pixels[3]};
    CHECK(got[0] == expect[0] && got[1] == expect[1] && got[2] == expect[2] && got[3] == expect[3],
          name, "signed integer clear lost sign or precision");
    printf("INFO %s: pixel=%d,%d,%d,%d\n", name, got[0], got[1], got[2], got[3]);
}

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
    int rc = submit_wait(d, cmd);
    if (rc == 0) {
        const uint8_t *center = (const uint8_t *)mapped + (32 * 64 + 32) * 4;
        // 片元 color = (uv,0,1)；像素中心 uv≈0.508 -> R/G≈129/130。容差 3 吸收栅格化/SIMD 取整。
        int r = center[0], g = center[1], b = center[2], a = center[3];
        CHECK(abs(r - 129) <= 3 && abs(g - 129) <= 3 && b == 0 && a == 255, name,
              "center pixel is not the hand-computed gradient");
        printf("INFO %s: center=%d,%d,%d,%d\n", name, r, g, b, a);
        printf("INFO %s: draw completed (full-screen triangle, no vertex buffers)\n", name);
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

static int compute_case(struct s2a_vk_device *d, const char *path) {
    const char *name = "compute-ssbo";
    VkDeviceMemory input_memory = VK_NULL_HANDLE;
    void *mapped = NULL;
    VkBuffer buffer = create_buffer(d, 64 * 4, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
                                    VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                                    &input_memory, &mapped);
    if (!buffer) { failures++; printf("FAIL %s: buffer\n", name); return -1; }
    memset(mapped, 0, 64 * 4);
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
    layout_info.setLayoutCount = 1; layout_info.pSetLayouts = &set_layout;
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
    VkDescriptorPoolSize pool_size = {VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1};
    VkDescriptorPoolCreateInfo pool_info = {0};
    pool_info.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
    pool_info.maxSets = 1; pool_info.poolSizeCount = 1; pool_info.pPoolSizes = &pool_size;
    VkDescriptorPool pool = VK_NULL_HANDLE;
    vkCreateDescriptorPool(d->device, &pool_info, NULL, &pool);
    VkDescriptorSetAllocateInfo alloc = {0};
    alloc.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
    alloc.descriptorPool = pool; alloc.descriptorSetCount = 1; alloc.pSetLayouts = &set_layout;
    VkDescriptorSet set = VK_NULL_HANDLE;
    vkAllocateDescriptorSets(d->device, &alloc, &set);
    VkDescriptorBufferInfo buffer_info = {buffer, 0, VK_WHOLE_SIZE};
    VkWriteDescriptorSet write = {0};
    write.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    write.dstSet = set; write.dstBinding = 0; write.descriptorCount = 1;
    write.descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
    write.pBufferInfo = &buffer_info;
    if (!module || !set_layout || !layout || pipe_result != VK_SUCCESS || !pool || !set) {
        failures++; printf("FAIL %s: pipeline/descriptor creation\n", name); return -1;
    }
    vkUpdateDescriptorSets(d->device, 1, &write, 0, NULL);
    VkCommandBuffer cmd = one_shot(d);
    vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, pipeline);
    vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, layout, 0, 1, &set, 0, NULL);
    vkCmdDispatch(cmd, 8, 1, 1);
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
        uint32_t *values = mapped;
        int bad = 0;
        for (uint32_t i = 0; i < 64; i++) if (values[i] != i * 3u + 1u) bad++;
        CHECK(bad == 0, name, "SSBO values differ from hand-computed 3*i+1");
        printf("INFO %s: first=%u,last=%u,bad=%d\n", name, values[0], values[63], bad);
    } else { failures++; printf("FAIL %s: submit/wait\n", name); }
    vkUnmapMemory(d->device, input_memory);
    vkDestroyDescriptorPool(d->device, pool, NULL);
    vkDestroyPipeline(d->device, pipeline, NULL);
    vkDestroyPipelineLayout(d->device, layout, NULL);
    vkDestroyDescriptorSetLayout(d->device, set_layout, NULL);
    vkDestroyShaderModule(d->device, module, NULL);
    vkDestroyBuffer(d->device, buffer, NULL); vkFreeMemory(d->device, input_memory, NULL);
    return rc;
}

static int copy_case(struct s2a_vk_device *d) {
    const char *name = "buffer-copy";
    VkDeviceMemory src_mem = VK_NULL_HANDLE, dst_mem = VK_NULL_HANDLE;
    void *src_map = NULL, *dst_map = NULL;
    VkBuffer src = create_buffer(d, 256, VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                                 VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                                 &src_mem, &src_map);
    VkBuffer dst = create_buffer(d, 256, VK_BUFFER_USAGE_TRANSFER_DST_BIT,
                                 VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                                 &dst_mem, &dst_map);
    if (!src || !dst) { failures++; printf("FAIL %s: buffer\n", name); return -1; }
    for (int i = 0; i < 256; i++) ((uint8_t *)src_map)[i] = (uint8_t)(i * 7 + 3);
    memset(dst_map, 0, 256);
    VkCommandBuffer cmd = one_shot(d);
    VkBufferCopy region = {0, 0, 256};
    vkCmdCopyBuffer(cmd, src, dst, 1, &region);
    VkBufferMemoryBarrier barrier = {0};
    barrier.sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER;
    barrier.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    barrier.dstAccessMask = VK_ACCESS_HOST_READ_BIT;
    barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barrier.buffer = dst; barrier.size = VK_WHOLE_SIZE;
    vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT,
                         0, 0, NULL, 1, &barrier, 0, NULL);
    int rc = submit_wait(d, cmd);
    if (rc == 0) {
        int bad = 0;
        for (int i = 0; i < 256; i++) if (((uint8_t *)dst_map)[i] != (uint8_t)(i * 7 + 3)) bad++;
        CHECK(bad == 0, name, "buffer copy differs from source pattern");
        printf("INFO %s: bad=%d\n", name, bad);
    } else { failures++; printf("FAIL %s: submit/wait\n", name); }
    vkUnmapMemory(d->device, src_mem); vkUnmapMemory(d->device, dst_mem);
    vkDestroyBuffer(d->device, src, NULL); vkFreeMemory(d->device, src_mem, NULL);
    vkDestroyBuffer(d->device, dst, NULL); vkFreeMemory(d->device, dst_mem, NULL);
    return rc;
}

int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "usage: vk_micro <shader-dir>\n"); return 2; }
    struct s2a_vk_device device;
    char why[192] = "";
    if (s2a_vk_device_create(&device, why, sizeof why)) {
        printf("FAIL device: %s\n", why);
        return 1;
    }
    printf("INFO device: %s api=%u.%u.%u driver=%u name=%s maintenance1=%d\n",
        device.properties.deviceName, VK_VERSION_MAJOR(device.properties.apiVersion),
        VK_VERSION_MINOR(device.properties.apiVersion), VK_VERSION_PATCH(device.properties.apiVersion),
        device.properties.driverVersion, device.driver_name, device.swapchain_maintenance1_enabled);
    char path[512];
    VkClearColorValue clear = {0};
    clear.float32[0] = 0.25f; clear.float32[1] = 0.5f; clear.float32[2] = 0.75f; clear.float32[3] = 1.0f;
    clear_case(&device, VK_FORMAT_R8G8B8A8_UNORM, clear, verify_clear_rgba8, "clear-rgba8", "float clear quantised");
    VkClearColorValue sint_clear = {0};
    sint_clear.int32[0] = -128; sint_clear.int32[1] = -1; sint_clear.int32[2] = 0; sint_clear.int32[3] = 127;
    clear_case(&device, VK_FORMAT_R8G8B8A8_SINT, sint_clear, verify_clear_sint8, "clear-sint8", "signed integer clear");
    snprintf(path, sizeof path, "%s/tri.vert.spv", argv[1]);
    char frag[512];
    snprintf(frag, sizeof frag, "%s/tri.frag.spv", argv[1]);
    draw_case(&device, path, frag);
    snprintf(path, sizeof path, "%s/fill.comp.spv", argv[1]);
    compute_case(&device, path);
    copy_case(&device);
    s2a_vk_device_destroy(&device, 0);
    if (failures) { printf("vk-micro: %d FAILURES\n", failures); return 1; }
    printf("vk-micro: ok\n");
    return 0;
}
