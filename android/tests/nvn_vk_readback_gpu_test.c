// NVN ReadTexels 的 GPU 图像路径宿主回归（需要 CPU Vulkan 参考实现 lavapipe）。
//
// 覆盖真机路径里最容易写错的一段：区域/子资源落成 VkBufferImageCopy（imageOffset /
// imageExtent / imageSubresource.baseArrayLayer + imageOffset.z）、staging → dst 的行距/层距
// 打包、以及“图像存储格式与 NVN 格式不同必须失败”的格式闸门。
//
// 只编生产实现：nvn_vk_readback_gpu.c + nvn_vk_readback_plan.c + nvn_vk_format.c + vk_device.c。
// 不替身 Vulkan：在 lavapipe 上真的建图像、真的拷回。脚本在缺 lavapipe 时退 2（不静默跳过）。
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <vulkan/vulkan.h>

#include "vk_device.h"
#include "nvn_vk_format.h"
#include "nvn_vk_readback.h"
#include "nvn_vk_readback_plan.h"
#include "nvn_vk_texcache.h"

int __android_log_print(int prio, const char *tag, const char *fmt, ...) {
    (void)prio; (void)tag; (void)fmt;
    return 0;
}

static int g_fail, g_checks;
#define CHECK(cond) do { g_checks++; if (!(cond)) { g_fail++; \
    printf("    FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); } } while (0)
#define CASE(name) do { printf("  case %-46s", name); } while (0)
#define END_CASE() do { printf("\n"); } while (0)

static struct s2a_vk_device g_dev;

enum { NVN_FMT_RGBA8 = 0x25 };

// 建一张 host-visible 的 buffer 并把 src 拷进内存（用于填充图像）。
static int create_fill_buffer(size_t bytes, VkBuffer *buf_out, VkDeviceMemory *mem_out, void **map_out) {
    VkBufferCreateInfo bi = {0};
    bi.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
    bi.size = bytes;
    bi.usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT;
    if (vkCreateBuffer(g_dev.device, &bi, NULL, buf_out) != VK_SUCCESS) return -1;
    VkMemoryRequirements req;
    vkGetBufferMemoryRequirements(g_dev.device, *buf_out, &req);
    VkMemoryAllocateInfo ai = {0};
    ai.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    ai.allocationSize = req.size;
    ai.memoryTypeIndex = s2a_vk_memory_type(&g_dev, req.memoryTypeBits,
        VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, NULL);
    if (ai.memoryTypeIndex == UINT32_MAX) return -1;
    if (vkAllocateMemory(g_dev.device, &ai, NULL, mem_out) != VK_SUCCESS) return -1;
    if (vkBindBufferMemory(g_dev.device, *buf_out, *mem_out, 0) != VK_SUCCESS) return -1;
    if (vkMapMemory(g_dev.device, *mem_out, 0, VK_WHOLE_SIZE, 0, map_out) != VK_SUCCESS) return -1;
    return 0;
}

static void destroy_fill_buffer(VkBuffer buf, VkDeviceMemory mem, void *map) {
    if (map) vkUnmapMemory(g_dev.device, mem);
    vkDestroyBuffer(g_dev.device, buf, NULL);
    vkFreeMemory(g_dev.device, mem, NULL);
}

static VkImage create_image(VkImageType type, uint32_t w, uint32_t h, uint32_t d, uint32_t layers,
                            VkFormat fmt, VkDeviceMemory *mem_out) {
    VkImageCreateInfo ci = {0};
    ci.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    ci.imageType = type;
    ci.format = fmt;
    ci.extent = (VkExtent3D){w, h, d};
    ci.mipLevels = 1;
    ci.arrayLayers = layers;
    ci.samples = VK_SAMPLE_COUNT_1_BIT;
    ci.tiling = VK_IMAGE_TILING_OPTIMAL;
    ci.usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_SAMPLED_BIT;
    ci.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    VkImage img = VK_NULL_HANDLE;
    if (vkCreateImage(g_dev.device, &ci, NULL, &img) != VK_SUCCESS) return VK_NULL_HANDLE;
    VkMemoryRequirements req;
    vkGetImageMemoryRequirements(g_dev.device, img, &req);
    VkMemoryAllocateInfo ai = {0};
    ai.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    ai.allocationSize = req.size;
    ai.memoryTypeIndex = s2a_vk_memory_type(&g_dev, req.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, NULL);
    if (ai.memoryTypeIndex == UINT32_MAX || vkAllocateMemory(g_dev.device, &ai, NULL, mem_out) != VK_SUCCESS ||
        vkBindImageMemory(g_dev.device, img, *mem_out, 0) != VK_SUCCESS) return VK_NULL_HANDLE;
    return img;
}

static int submit_and_wait(VkCommandBuffer cmd) {
    VkFenceCreateInfo fi = {0};
    fi.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
    VkFence fence = VK_NULL_HANDLE;
    if (vkCreateFence(g_dev.device, &fi, NULL, &fence) != VK_SUCCESS) return -1;
    VkSubmitInfo si = {0};
    si.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
    si.commandBufferCount = 1;
    si.pCommandBuffers = &cmd;
    VkResult vr = vkQueueSubmit(g_dev.queue, 1, &si, fence);
    if (vr == VK_SUCCESS) vr = vkWaitForFences(g_dev.device, 1, &fence, VK_TRUE, 30000000000ull);
    vkDestroyFence(g_dev.device, fence, NULL);
    return vr == VK_SUCCESS ? 0 : -1;
}

// 把 src（每层/切片 img_stride 字节、每行 row_bytes 字节）填进图像（GENERAL 布局）。
static int fill_image(VkImage img, VkImageType type, uint32_t w, uint32_t h, uint32_t d, uint32_t layers,
                      const void *src, size_t row_bytes, size_t img_stride) {
    const size_t bytes = img_stride * (type == VK_IMAGE_TYPE_3D ? d : layers);
    VkBuffer buf = VK_NULL_HANDLE;
    VkDeviceMemory mem = VK_NULL_HANDLE;
    void *map = NULL;
    if (create_fill_buffer(bytes, &buf, &mem, &map)) return -1;
    memcpy(map, src, bytes);

    VkCommandBufferAllocateInfo ca = {0};
    ca.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    ca.commandPool = g_dev.command_pool;
    ca.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    ca.commandBufferCount = 1;
    VkCommandBuffer cmd = VK_NULL_HANDLE;
    if (vkAllocateCommandBuffers(g_dev.device, &ca, &cmd) != VK_SUCCESS) return -1;
    VkCommandBufferBeginInfo cb = {0};
    cb.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    cb.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    vkBeginCommandBuffer(cmd, &cb);
    VkImageMemoryBarrier to = {0};
    to.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
    to.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    to.newLayout = VK_IMAGE_LAYOUT_GENERAL;
    to.srcQueueFamilyIndex = to.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    to.image = img;
    to.subresourceRange = (VkImageSubresourceRange){VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, layers};
    to.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0,
                         0, NULL, 0, NULL, 1, &to);
    const uint32_t nz = type == VK_IMAGE_TYPE_3D ? d : layers;
    for (uint32_t z = 0; z < nz; z++) {
        VkBufferImageCopy c = {0};
        c.bufferOffset = (VkDeviceSize)z * img_stride;
        c.imageSubresource = (VkImageSubresourceLayers){VK_IMAGE_ASPECT_COLOR_BIT, 0, type == VK_IMAGE_TYPE_3D ? 0 : z, 1};
        c.imageOffset = (VkOffset3D){0, 0, type == VK_IMAGE_TYPE_3D ? (int32_t)z : 0};
        c.imageExtent = (VkExtent3D){w, h, 1};
        vkCmdCopyBufferToImage(cmd, buf, img, VK_IMAGE_LAYOUT_GENERAL, 1, &c);
    }
    vkEndCommandBuffer(cmd);
    int rc = submit_and_wait(cmd);
    vkFreeCommandBuffers(g_dev.device, g_dev.command_pool, 1, &cmd);
    destroy_fill_buffer(buf, mem, map);
    return rc;
}

static void destroy_image(VkImage img, VkDeviceMemory mem) {
    vkDestroyImage(g_dev.device, img, NULL);
    vkFreeMemory(g_dev.device, mem, NULL);
}

// 逐行比对读回结果与源图。src 是填充用的整幅图（行距 row_bytes、层距 img_stride）。
static int check_region(const uint8_t *dst, const uint8_t *src, const struct nvn_vk_rb_plan *p,
                        size_t row_bytes, size_t img_stride, uint32_t xoff_texels) {
    const uint32_t bpp = (uint32_t)p->bpb;
    for (uint32_t z = 0; z < p->nz; z++) {
        // 3D：源切片号 = zoffset + z；2D 数组/立方体：源层号 = layer0 + zoffset + z。
        const uint32_t src_z = (p->is3d ? p->z : p->layer0 + p->z) + z;
        for (uint32_t y = 0; y < p->block_rows; y++) {
            const uint8_t *want = src + (size_t)src_z * img_stride +
                                  (size_t)(p->y + y) * row_bytes + (size_t)xoff_texels * bpp;
            const uint8_t *got = dst + (size_t)z * p->dst_img + (size_t)y * p->dst_row;
            if (memcmp(got, want, p->copy_row_bytes)) {
                printf("    FAIL region mismatch z=%u y=%u (%u B)\n", z, y, p->copy_row_bytes);
                return -1;
            }
        }
    }
    return 0;
}

static struct nvn_vk_rb_desc rgba8_desc(int32_t target, uint32_t w, uint32_t h, uint32_t d, uint32_t layers) {
    struct nvn_vk_rb_desc o;
    memset(&o, 0, sizeof o);
    o.nvn_format = NVN_FMT_RGBA8;
    o.target = target;
    o.bpb = 4; o.bw = 1; o.bh = 1;
    o.width = w; o.height = h; o.depth = d; o.levels = 1; o.layers = layers;
    return o;
}

// 2D 数组：子区域 + layer0/zoffset 映射 + 行距/层距 padding。
static void case_2d_array(void) {
    CASE("2d array sub-region + padded strides");
    const uint32_t w = 64, h = 32, layers = 4;
    const size_t row_bytes = w * 4, img_stride = row_bytes * h;
    uint8_t *src = (uint8_t *)malloc(img_stride * layers);
    for (size_t i = 0; i < img_stride * layers; i++) src[i] = (uint8_t)(i * 7u + 3u);
    VkDeviceMemory mem = VK_NULL_HANDLE;
    VkImage img = create_image(VK_IMAGE_TYPE_2D, w, h, 1, layers, VK_FORMAT_R8G8B8A8_UNORM, &mem);
    CHECK(img != VK_NULL_HANDLE);
    if (img) {
        CHECK(fill_image(img, VK_IMAGE_TYPE_2D, w, h, 1, layers, src, row_bytes, img_stride) == 0);
        struct nvn_vk_tex tex;
        memset(&tex, 0, sizeof tex);
        tex.image = img; tex.nvn_format = NVN_FMT_RGBA8; tex.vk_format = VK_FORMAT_R8G8B8A8_UNORM;
        tex.width = w; tex.height = h; tex.depth = 1; tex.layers = layers; tex.serial = 11;
        struct nvn_vk_rb_desc desc = rgba8_desc(4 /*2D_ARRAY*/, w, h, 1, layers);
        struct nvn_vk_rb_region region = {8, 4, 1, 16, 16, 2};   // layer0=1 + zoffset=1 -> 层 2、3
        struct nvn_vk_rb_plan plan;
        char why[NVN_VK_RB_WHY_MAX] = "";
        CHECK(nvn_vk_readback_plan(&desc, 0, 1, &region, 96 /*row padding*/, 0, &plan, why, sizeof why) == 0);
        uint8_t *dst = (uint8_t *)calloc(1, nvn_vk_readback_dst_extent(&plan) + 16);
        CHECK(dst != NULL);
        if (dst) {
            CHECK(nvn_vk_readback_gpu(&g_dev, &tex, &plan, dst, why, sizeof why) == 0);
            // 层号按 layer0 + zoffset 起算：源图第 2、3 层。
            CHECK(check_region(dst, src, &plan, row_bytes, img_stride, 8) == 0);
            free(dst);
        }
        destroy_image(img, mem);
    }
    free(src);
    END_CASE();
}

// 3D：zoffset 落成 imageOffset.z，dst 按层距累加。
static void case_3d(void) {
    CASE("3d texture slice mapping");
    const uint32_t w = 32, h = 16, d = 6;
    const size_t row_bytes = w * 4, img_stride = row_bytes * h;
    uint8_t *src = (uint8_t *)malloc(img_stride * d);
    for (size_t i = 0; i < img_stride * d; i++) src[i] = (uint8_t)(i * 13u + 5u);
    VkDeviceMemory mem = VK_NULL_HANDLE;
    VkImage img = create_image(VK_IMAGE_TYPE_3D, w, h, d, 1, VK_FORMAT_R8G8B8A8_UNORM, &mem);
    CHECK(img != VK_NULL_HANDLE);
    if (img) {
        CHECK(fill_image(img, VK_IMAGE_TYPE_3D, w, h, d, 1, src, row_bytes, img_stride) == 0);
        struct nvn_vk_tex tex;
        memset(&tex, 0, sizeof tex);
        tex.image = img; tex.nvn_format = NVN_FMT_RGBA8; tex.vk_format = VK_FORMAT_R8G8B8A8_UNORM;
        tex.width = w; tex.height = h; tex.depth = d; tex.layers = 1; tex.serial = 12;
        struct nvn_vk_rb_desc desc = rgba8_desc(2 /*3D*/, w, h, d, 1);
        struct nvn_vk_rb_region region = {0, 0, 2, 32, 16, 3};
        struct nvn_vk_rb_plan plan;
        char why[NVN_VK_RB_WHY_MAX] = "";
        CHECK(nvn_vk_readback_plan(&desc, 0, 0, &region, 0, 0, &plan, why, sizeof why) == 0);
        uint8_t *dst = (uint8_t *)calloc(1, nvn_vk_readback_dst_extent(&plan) + 16);
        CHECK(dst != NULL);
        if (dst) {
            CHECK(nvn_vk_readback_gpu(&g_dev, &tex, &plan, dst, why, sizeof why) == 0);
            CHECK(check_region(dst, src, &plan, row_bytes, img_stride, 0) == 0);
            free(dst);
        }
        destroy_image(img, mem);
    }
    free(src);
    END_CASE();
}

// 图像存储格式与 NVN 格式不同（BC 解码/展开）：必须明确失败，不能把解码后的像素当 NVN 字节。
static void case_format_mismatch(void) {
    CASE("format mismatch is refused");
    VkDeviceMemory mem = VK_NULL_HANDLE;
    VkImage img = create_image(VK_IMAGE_TYPE_2D, 8, 8, 1, 1, VK_FORMAT_R8G8B8A8_UNORM, &mem);
    CHECK(img != VK_NULL_HANDLE);
    if (img) {
        struct nvn_vk_tex tex;
        memset(&tex, 0, sizeof tex);
        tex.image = img;
        tex.nvn_format = 0x4B;   // NVN_FORMAT_RGTC1_UNORM（BC4）
        tex.vk_format = VK_FORMAT_R8G8B8A8_UNORM;
        tex.width = 8; tex.height = 8; tex.layers = 1; tex.serial = 13;
        struct nvn_vk_rb_desc desc = rgba8_desc(1, 8, 8, 1, 1);
        desc.nvn_format = 0x4B; desc.bpb = 8; desc.bw = 4; desc.bh = 4;
        struct nvn_vk_rb_region region = {0, 0, 0, 8, 8, 1};
        struct nvn_vk_rb_plan plan;
        char why[NVN_VK_RB_WHY_MAX] = "";
        CHECK(nvn_vk_readback_plan(&desc, 0, 0, &region, 0, 0, &plan, why, sizeof why) == 0);
        uint8_t dst[256];
        why[0] = 0;
        CHECK(nvn_vk_readback_gpu(&g_dev, &tex, &plan, dst, why, sizeof why) != 0);
        CHECK(strstr(why, "VkFormat") != NULL);
        destroy_image(img, mem);
    }
    END_CASE();
}

int main(void) {
    char why[256] = {0};
    if (s2a_vk_device_create(&g_dev, why, sizeof why) != 0) {
        printf("SKIP? 建 Vulkan 设备失败：%s\n", why);
        return 2;   // 不静默跳过：脚本把 2 当红
    }
    printf("device: %s (%s)\n", g_dev.properties.deviceName, g_dev.driver_name);
    case_2d_array();
    case_3d();
    case_format_mismatch();
    nvn_vk_readback_gpu_release(&g_dev);
    s2a_vk_device_destroy(&g_dev, 0);
    printf("%s: %d checks, %d failed\n", g_fail ? "FAIL" : "PASS", g_checks, g_fail);
    return g_fail ? 1 : 0;
}
