#include <stdio.h>
#include <string.h>
#include "nvn_vk_pipeline.h"
int main(int argc, char **argv) {
    if (argc < 3) { printf("usage: %s a.blob b.blob\n", argv[0]); return 2; }
    struct s2a_vk_device d; char why[192] = "";
    if (s2a_vk_device_create(&d, why, sizeof why)) { printf("FAIL device: %s\n", why); return 1; }
    struct nvn_vk_pipeline_cache c; nvn_vk_pipeline_init(&c, &d);
    struct nvn_vk_vertex_layout vl; memset(&vl, 0, sizeof vl);
    vl.binding_count = 1; vl.bindings[0] = (VkVertexInputBindingDescription){0, 16, VK_VERTEX_INPUT_RATE_VERTEX};
    vl.attribute_count = 1; vl.attributes[0] = (VkVertexInputAttributeDescription){0, 0, VK_FORMAT_R32G32B32A32_SFLOAT, 0};
    VkPipeline a = nvn_vk_pipeline_get(&c, argv[1], VK_FORMAT_R8G8B8A8_UNORM, &vl, why, sizeof why);
    VkPipeline a2 = nvn_vk_pipeline_get(&c, argv[1], VK_FORMAT_R8G8B8A8_UNORM, &vl, why, sizeof why);
    VkPipeline b = nvn_vk_pipeline_get(&c, argv[2], VK_FORMAT_R8G8B8A8_UNORM, &vl, why, sizeof why);
    VkPipeline a3 = nvn_vk_pipeline_get(&c, argv[1], VK_FORMAT_B8G8R8A8_UNORM, &vl, why, sizeof why);
    VkDescriptorSet s1[4] = {0}, s2[4] = {0};
    int sets_ok = a && nvn_vk_pipeline_sets(&c, a, s1) == 0 && nvn_vk_pipeline_sets(&c, a, s2) == 0 &&
                  s1[0] && s1[1] && s1[2] && s1[3] && s1[0] == s2[0] && s1[3] == s2[3];
    int upd_ok = 0;
    if (a) {
        VkBufferCreateInfo bi = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO };
        bi.size = 4096; bi.usage = VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT;
        VkBuffer buf = VK_NULL_HANDLE;
        if (vkCreateBuffer(d.device, &bi, NULL, &buf) == VK_SUCCESS) {
            VkMemoryRequirements mr; vkGetBufferMemoryRequirements(d.device, buf, &mr);
            VkMemoryAllocateInfo ai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO };
            ai.allocationSize = mr.size;
            ai.memoryTypeIndex = s2a_vk_memory_type(&d, mr.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, NULL);
            VkDeviceMemory mem = VK_NULL_HANDLE;
            if (vkAllocateMemory(d.device, &ai, NULL, &mem) == VK_SUCCESS && vkBindBufferMemory(d.device, buf, mem, 0) == VK_SUCCESS) {
                void *map = NULL;
                if (vkMapMemory(d.device, mem, 0, 2608, 0, &map) == VK_SUCCESS) { memset(map, 0, 2608); vkUnmapMemory(d.device, mem); }
                upd_ok = nvn_vk_pipeline_update_ubo(&c, a, 0, 0, buf, 0, 2608) == 0;
            }
            if (mem) vkFreeMemory(d.device, mem, NULL);
            vkDestroyBuffer(d.device, buf, NULL);
        }
    }
    int tex_ok = 0;
    if (b) {
        VkImageCreateInfo ici = { VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO };
        ici.imageType = VK_IMAGE_TYPE_2D; ici.format = VK_FORMAT_R8G8B8A8_UNORM;
        ici.extent = (VkExtent3D){1, 1, 1}; ici.mipLevels = 1; ici.arrayLayers = 1;
        ici.samples = VK_SAMPLE_COUNT_1_BIT; ici.tiling = VK_IMAGE_TILING_OPTIMAL;
        ici.usage = VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT;
        VkImage img = VK_NULL_HANDLE;
        if (vkCreateImage(d.device, &ici, NULL, &img) == VK_SUCCESS) {
            VkMemoryRequirements mr; vkGetImageMemoryRequirements(d.device, img, &mr);
            VkMemoryAllocateInfo ai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO };
            ai.allocationSize = mr.size;
            ai.memoryTypeIndex = s2a_vk_memory_type(&d, mr.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, NULL);
            VkDeviceMemory mem = VK_NULL_HANDLE;
            if (vkAllocateMemory(d.device, &ai, NULL, &mem) == VK_SUCCESS && vkBindImageMemory(d.device, img, mem, 0) == VK_SUCCESS) {
                VkImageViewCreateInfo vci = { VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO };
                vci.image = img; vci.viewType = VK_IMAGE_VIEW_TYPE_2D; vci.format = VK_FORMAT_R8G8B8A8_UNORM;
                vci.subresourceRange = (VkImageSubresourceRange){VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
                VkImageView view = VK_NULL_HANDLE;
                VkSamplerCreateInfo sci = { VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO };
                VkSampler samp = VK_NULL_HANDLE;
                if (vkCreateImageView(d.device, &vci, NULL, &view) == VK_SUCCESS &&
                    vkCreateSampler(d.device, &sci, NULL, &samp) == VK_SUCCESS)
                    tex_ok = nvn_vk_pipeline_update_tex(&c, b, 2, 0, view, samp) == 0;
                if (samp) vkDestroySampler(d.device, samp, NULL);
                if (view) vkDestroyImageView(d.device, view, NULL);
            }
            if (mem) vkFreeMemory(d.device, mem, NULL);
            vkDestroyImage(d.device, img, NULL);
        }
    }
    int draw_ok = 0; uint32_t center = 0;
    if (a && upd_ok) {
        VkImageCreateInfo ci = { VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO };
        ci.imageType = VK_IMAGE_TYPE_2D; ci.format = VK_FORMAT_R8G8B8A8_UNORM; ci.extent = (VkExtent3D){4,4,1};
        ci.mipLevels = 1; ci.arrayLayers = 1; ci.samples = VK_SAMPLE_COUNT_1_BIT; ci.tiling = VK_IMAGE_TILING_OPTIMAL;
        ci.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
        VkImage img = VK_NULL_HANDLE; vkCreateImage(d.device, &ci, NULL, &img);
        VkMemoryRequirements mr; vkGetImageMemoryRequirements(d.device, img, &mr);
        VkMemoryAllocateInfo ai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO };
        ai.allocationSize = mr.size; ai.memoryTypeIndex = s2a_vk_memory_type(&d, mr.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, NULL);
        VkDeviceMemory imem = VK_NULL_HANDLE; vkAllocateMemory(d.device, &ai, NULL, &imem); vkBindImageMemory(d.device, img, imem, 0);
        VkImageViewCreateInfo vci = { VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO };
        vci.image = img; vci.viewType = VK_IMAGE_VIEW_TYPE_2D; vci.format = VK_FORMAT_R8G8B8A8_UNORM;
        vci.subresourceRange = (VkImageSubresourceRange){VK_IMAGE_ASPECT_COLOR_BIT,0,1,0,1};
        VkImageView view = VK_NULL_HANDLE; vkCreateImageView(d.device, &vci, NULL, &view);
        // UNDEFINED -> COLOR_ATTACHMENT_OPTIMAL（helper 假定目标已在该布局）
        {
            VkCommandBufferAllocateInfo cai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO };
            cai.commandPool = d.command_pool; cai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY; cai.commandBufferCount = 1;
            VkCommandBuffer cmd = VK_NULL_HANDLE; vkAllocateCommandBuffers(d.device, &cai, &cmd);
            VkCommandBufferBeginInfo bi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO }; bi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
            vkBeginCommandBuffer(cmd, &bi);
            VkImageMemoryBarrier b = { VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER };
            b.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED; b.newLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
            b.srcQueueFamilyIndex = b.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED; b.image = img;
            b.subresourceRange = (VkImageSubresourceRange){VK_IMAGE_ASPECT_COLOR_BIT,0,1,0,1};
            b.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
            vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, 0, 0, NULL, 0, NULL, 1, &b);
            vkEndCommandBuffer(cmd);
            VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO }; si.commandBufferCount = 1; si.pCommandBuffers = &cmd;
            VkFenceCreateInfo fci = { VK_STRUCTURE_TYPE_FENCE_CREATE_INFO }; VkFence fence = VK_NULL_HANDLE; vkCreateFence(d.device, &fci, NULL, &fence);
            vkQueueSubmit(d.queue, 1, &si, fence); vkWaitForFences(d.device, 1, &fence, VK_TRUE, 2000000000ull);
            vkDestroyFence(d.device, fence, NULL); vkFreeCommandBuffers(d.device, d.command_pool, 1, &cmd);
        }
        const float verts[3][4] = {{-1,-1,0,1},{3,-1,0,1},{-1,3,0,1}};
        VkBufferCreateInfo ubci = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO };
        ubci.size = 2608; ubci.usage = VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT;
        VkBuffer ubo = VK_NULL_HANDLE; vkCreateBuffer(d.device, &ubci, NULL, &ubo);
        VkMemoryRequirements umr; vkGetBufferMemoryRequirements(d.device, ubo, &umr);
        VkMemoryAllocateInfo uai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO };
        uai.allocationSize = umr.size;
        uai.memoryTypeIndex = s2a_vk_memory_type(&d, umr.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, NULL);
        VkDeviceMemory umem = VK_NULL_HANDLE; vkAllocateMemory(d.device, &uai, NULL, &umem); vkBindBufferMemory(d.device, ubo, umem, 0);
        void *up = NULL; if (vkMapMemory(d.device, umem, 0, 2608, 0, &up) == VK_SUCCESS) { memset(up, 0, 2608); vkUnmapMemory(d.device, umem); }
        if (nvn_vk_pipeline_draw(&c, a, view, 4, 4, verts, sizeof verts, ubo, 2608) == 0) {
            VkBufferCreateInfo rci = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO }; rci.size = 4*4*4; rci.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT;
            VkBuffer rb = VK_NULL_HANDLE; vkCreateBuffer(d.device, &rci, NULL, &rb);
            VkMemoryRequirements rmr; vkGetBufferMemoryRequirements(d.device, rb, &rmr);
            VkMemoryAllocateInfo rai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO };
            rai.allocationSize = rmr.size; rai.memoryTypeIndex = s2a_vk_memory_type(&d, rmr.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, NULL);
            VkDeviceMemory rmem = VK_NULL_HANDLE; vkAllocateMemory(d.device, &rai, NULL, &rmem); vkBindBufferMemory(d.device, rb, rmem, 0);
            VkCommandBufferAllocateInfo cai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO };
            cai.commandPool = d.command_pool; cai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY; cai.commandBufferCount = 1;
            VkCommandBuffer cmd = VK_NULL_HANDLE; vkAllocateCommandBuffers(d.device, &cai, &cmd);
            VkCommandBufferBeginInfo bi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO }; bi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
            vkBeginCommandBuffer(cmd, &bi);
            VkImageMemoryBarrier b = { VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER };
            b.oldLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL; b.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
            b.srcQueueFamilyIndex = b.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED; b.image = img;
            b.subresourceRange = (VkImageSubresourceRange){VK_IMAGE_ASPECT_COLOR_BIT,0,1,0,1};
            b.srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT; b.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
            vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1, &b);
            VkBufferImageCopy copy = {0}; copy.imageSubresource = (VkImageSubresourceLayers){VK_IMAGE_ASPECT_COLOR_BIT,0,0,1};
            copy.imageExtent = (VkExtent3D){4,4,1};
            vkCmdCopyImageToBuffer(cmd, img, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, rb, 1, &copy);
            vkEndCommandBuffer(cmd);
            VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO }; si.commandBufferCount = 1; si.pCommandBuffers = &cmd;
            VkFenceCreateInfo fci = { VK_STRUCTURE_TYPE_FENCE_CREATE_INFO }; VkFence fence = VK_NULL_HANDLE; vkCreateFence(d.device, &fci, NULL, &fence);
            if (vkQueueSubmit(d.queue, 1, &si, fence) == VK_SUCCESS && vkWaitForFences(d.device, 1, &fence, VK_TRUE, 2000000000ull) == VK_SUCCESS) {
                void *rp = NULL;
                if (vkMapMemory(d.device, rmem, 0, 4*4*4, 0, &rp) == VK_SUCCESS) {
                    const uint8_t *px = (const uint8_t *)rp;
                    center = (uint32_t)px[16] | (uint32_t)px[17] << 8 | (uint32_t)px[18] << 16 | (uint32_t)px[19] << 24;
                    draw_ok = px[16] > 200 && px[17] < 40 && px[18] < 40;
                    vkUnmapMemory(d.device, rmem);
                }
            }
            vkDestroyFence(d.device, fence, NULL);
            vkFreeCommandBuffers(d.device, d.command_pool, 1, &cmd);
            vkDestroyBuffer(d.device, rb, NULL); vkFreeMemory(d.device, rmem, NULL);
        }
        vkDestroyBuffer(d.device, ubo, NULL); vkFreeMemory(d.device, umem, NULL);
        vkDestroyImageView(d.device, view, NULL);
        vkDestroyImage(d.device, img, NULL);
        vkFreeMemory(d.device, imem, NULL);
    }
    int ok = a && a == a2 && b && b != a && a3 && a3 != a && sets_ok && upd_ok && tex_ok && draw_ok && c.created == 3 && c.reused == 1;
    printf("a=%p a2=%p b=%p a3=%p created=%u reused=%u draw=0x%08x why=%s\n", (void*)a, (void*)a2, (void*)b, (void*)a3, c.created, c.reused, center, why);
    printf("nvn-vk-pipeline: %s\n", ok ? "ok" : "FAIL");
    nvn_vk_pipeline_destroy(&c); s2a_vk_device_destroy(&d, 0);
    return ok ? 0 : 1;
}
