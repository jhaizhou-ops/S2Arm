// BC/块压缩纹理作为渲染目标（“块=像素”影子）的字节级往返回归：纯判定 + 真 Vulkan。
//
// 生产契约（nvn/nvn_vk_mrt.h 的 nvn_vk_bcrt_*）：TOTK 把 32x32x32 RGTC1(BC4) 3D 纹理的每个深度
// 切片当渲染目标，附件视图用 RGBA16UI 覆盖——一个视图像素 = 一个 8 字节 BC4 块。Vulkan 既不能把
// 压缩格式当颜色附件，也不能建压缩↔无压缩视图，所以生产走“等尺寸 2D 影子 + 一块 buffer”：
//   pass 前  底图(压缩) --img_to_buf--> buffer --buf_to_shadow--> 影子(视图格式, bw×bh)
//   pass 后  影子 --shadow_to_buf--> buffer --buf_to_img--> 底图(压缩)
// 全程字节原样搬运（Vulkan 规则：压缩格式不能当颜色附件、不能建无压缩视图，image→image 拷贝
// 又要求格式兼容），不做解码/重编码；影子行字节数
// 恰好等于压缩底图块行字节数（bw*block_bytes = bw*视图像素字节数），所以两次拷贝都是紧打包。
//
// 本用例不复制生产算法：拷贝区域一律由生产 nvn_vk_bcrt_* 构造，测试只录命令、比字节。
//   A. 纯判定（不需要 Vulkan）：格式覆盖判定、拒绝原因、拷贝区域（3D 用 imageOffset.z、2D 数组用
//      baseArrayLayer、影子 extent=bw×bh、bufferRowLength/ImageHeight 为 0 紧打包）。
//   B. 真 Vulkan（宿主 lavapipe 与真机 Adreno 同一份源码）：
//      7) 3D BC4 32x32x4，不同平面不同字节 → 经影子往返只改 plane 2，plane 0/1/3 未动；
//      8) 2D BC4 32x32 mip3 层4 → 只改 (mip2, layer3)，mip2-layer0 / mip0-layer3 / mip0-layer0 未动；
//      9) 影子直写路径：直接对影子 vkCmdCopyBufferToImage 写新字节 → 影子→buffer→底图，读回与
//         写入逐字节一致（证明是字节搬运，不是格式转换/重编码）。
//   C. 失败路径：拒绝时 why 非空且说清原因；影子尺寸 ceil(width/4)×ceil(height/4)（32/30/31→8、1→1）。
//
// 反例（改坏必红）：
//   · 3D 切片按 array layer 选（3D 的 layerCount 恒 1，只有 imageOffset.z 能选深度切片）；
//   · 影子按 width×height 建（块=像素应为 ceil(w/4)×ceil(h/4)）或 extent 混用 → 越界/只拷左上角；
//   · 往返做格式转换/解码重编码 → 任意字节模式对不回去（用例刻意用非“像素化”的字节模式）；
//   · bufferRowLength 非 0 或按像素行/块行混用 → 行距错。
//
// 打桩：只建 device/queue/命令池/栅栏/图像/缓冲，不建 session、不链帧队列。影子按生产附件用法建
// （含 COLOR_ATTACHMENT），但本用例不做真绘制；影子写入用 transfer 模拟 shader 写（与生产 pass
// 前后两次拷贝的字节口径一致，真绘制留给真机探针之外的渲染回归）。
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "nvn/nvn_vk_mrt.h"
#include "vk_device.h"

// vk_device.c 在 Android 上引用 bionic/liblog；宿主回归给这两个符号打桩，
// 真机探针链接 liblog 时由本文件里的定义优先（与 nvn_vk_feedback_snapshot_test.c 同口径）。
int __android_log_print(int prio, const char *tag, const char *fmt, ...) {
    (void)prio;
    (void)tag;
    (void)fmt;
    return 0;
}
int __system_property_get(const char *name, char *value) {
    (void)name;
    if (value) value[0] = 0;
    return 0;
}

static struct s2a_vk_device D;
static int fails;
static int checks;

// ---------- 断言：每条失败都打 “✗ <定位>：期望 …，真结果 …” ----------

static void failf(const char *label, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    printf("✗ %s：", label);
    vprintf(fmt, ap);
    printf("\n");
    fflush(stdout);
    va_end(ap);
    fails++;
}

static void ck_u32(const char *label, uint32_t got, uint32_t want) {
    checks++;
    if (got != want) failf(label, "期望 %u，真结果 %u", (unsigned)want, (unsigned)got);
}

static void ck_i32(const char *label, int32_t got, int32_t want) {
    checks++;
    if (got != want) failf(label, "期望 %d，真结果 %d", (int)want, (int)got);
}

static void ck_u64(const char *label, uint64_t got, uint64_t want) {
    checks++;
    if (got != want) failf(label, "期望 %llu，真结果 %llu",
                           (unsigned long long)want, (unsigned long long)got);
}

static void ck_true(const char *label, int ok, const char *expect) {
    checks++;
    if (!ok) failf(label, "期望 %s，真结果 不成立", expect);
}

static void ck_bytes(const char *label, const uint8_t *got, const uint8_t *want, size_t n) {
    size_t first = 0, diffs = 0, i;
    checks++;
    if (memcmp(got, want, n) == 0) return;
    for (i = 0; i < n; i++) {
        if (got[i] != want[i]) {
            if (!diffs) first = i;
            diffs++;
        }
    }
    failf(label, "期望 %zu 字节逐字节一致，真结果 首差 @%zu 期望=0x%02x 真结果=0x%02x，共 %zu 字节不符",
          n, first, (unsigned)want[first], (unsigned)got[first], diffs);
}

// ---------- 生产计划判定：接受 / 拒绝 / 字段 ----------

// 返回 0 = 生产判定接受且 out 已填；-1 = 拒绝（打红）。
static int plan_accept(const char *tag, VkFormat base, VkFormat view, uint32_t w, uint32_t h,
                       uint32_t level, uint32_t layer, uint8_t is_3d,
                       struct nvn_vk_bcrt_plan *out) {
    char why[256] = "";
    char label[192];
    int rc = nvn_vk_bcrt_plan_make(base, view, w, h, level, layer, is_3d, out, why, sizeof why);
    snprintf(label, sizeof label, "%s 判定", tag);
    checks++;
    if (rc != 0) {
        failf(label, "期望 接受（rc=0），真结果 拒绝（rc=%d）why=\"%s\"", rc, why);
        return -1;
    }
    return 0;
}

// 期望生产判定拒绝，并检查 why 可定位（非空 + 命中关键词）。
static void plan_reject(const char *tag, VkFormat base, VkFormat view, uint32_t w, uint32_t h,
                        uint32_t level, uint32_t layer, uint8_t is_3d, const char *keyword) {
    char why[256] = "";
    struct nvn_vk_bcrt_plan p;
    char label[192];
    int rc = nvn_vk_bcrt_plan_make(base, view, w, h, level, layer, is_3d, &p, why, sizeof why);
    snprintf(label, sizeof label, "%s 判定", tag);
    checks++;
    if (rc == 0) {
        failf(label, "期望 拒绝（rc≠0），真结果 接受（rc=0）");
        return;
    }
    snprintf(label, sizeof label, "%s why 非空", tag);
    checks++;
    if (!why[0]) {
        failf(label, "期望 写明拒绝原因，真结果 空字符串");
        return;
    }
    if (keyword) {
        snprintf(label, sizeof label, "%s why 关键词", tag);
        checks++;
        if (!strstr(why, keyword))
            failf(label, "期望 why 含 \"%s\"，真结果 why=\"%s\"", keyword, why);
    }
}

static void ck_plan_fields(const char *tag, const struct nvn_vk_bcrt_plan *p, uint32_t block_bytes,
                           uint32_t w, uint32_t h, uint32_t level, uint32_t layer, uint32_t is_3d) {
    char label[192];
    snprintf(label, sizeof label, "%s block_bytes", tag);
    ck_u32(label, p->block_bytes, block_bytes);
    snprintf(label, sizeof label, "%s side", tag);
    ck_u32(label, p->side, 4);
    snprintf(label, sizeof label, "%s width", tag);
    ck_u32(label, p->width, w);
    snprintf(label, sizeof label, "%s height", tag);
    ck_u32(label, p->height, h);
    snprintf(label, sizeof label, "%s bw=ceil(w/4)", tag);
    ck_u32(label, p->bw, (w + 3) / 4);
    snprintf(label, sizeof label, "%s bh=ceil(h/4)", tag);
    ck_u32(label, p->bh, (h + 3) / 4);
    snprintf(label, sizeof label, "%s level", tag);
    ck_u32(label, p->level, level);
    snprintf(label, sizeof label, "%s layer", tag);
    ck_u32(label, p->layer, layer);
    snprintf(label, sizeof label, "%s is_3d", tag);
    ck_u32(label, p->is_3d, is_3d);
}

// 期望一个 VkBufferImageCopy（生产构造函数输出）的全部字段。
static void ck_copy_region(const char *tag, const VkBufferImageCopy *c, uint32_t mip,
                           uint32_t base_layer, int32_t z, uint32_t w, uint32_t h, uint32_t d) {
    char label[192];
    snprintf(label, sizeof label, "%s aspectMask", tag);
    ck_u32(label, (uint32_t)c->imageSubresource.aspectMask, (uint32_t)VK_IMAGE_ASPECT_COLOR_BIT);
    snprintf(label, sizeof label, "%s mipLevel", tag);
    ck_u32(label, c->imageSubresource.mipLevel, mip);
    snprintf(label, sizeof label, "%s baseArrayLayer", tag);
    ck_u32(label, c->imageSubresource.baseArrayLayer, base_layer);
    snprintf(label, sizeof label, "%s layerCount", tag);
    ck_u32(label, c->imageSubresource.layerCount, 1);
    snprintf(label, sizeof label, "%s bufferOffset", tag);
    ck_u64(label, (uint64_t)c->bufferOffset, 0);
    snprintf(label, sizeof label, "%s bufferRowLength(紧打包)", tag);
    ck_u32(label, c->bufferRowLength, 0);
    snprintf(label, sizeof label, "%s bufferImageHeight(紧打包)", tag);
    ck_u32(label, c->bufferImageHeight, 0);
    snprintf(label, sizeof label, "%s imageOffset.x", tag);
    ck_i32(label, c->imageOffset.x, 0);
    snprintf(label, sizeof label, "%s imageOffset.y", tag);
    ck_i32(label, c->imageOffset.y, 0);
    snprintf(label, sizeof label, "%s imageOffset.z", tag);
    ck_i32(label, c->imageOffset.z, z);
    snprintf(label, sizeof label, "%s imageExtent.width", tag);
    ck_u32(label, c->imageExtent.width, w);
    snprintf(label, sizeof label, "%s imageExtent.height", tag);
    ck_u32(label, c->imageExtent.height, h);
    snprintf(label, sizeof label, "%s imageExtent.depth", tag);
    ck_u32(label, c->imageExtent.depth, d);
}

// ---------- A：纯判定（不需要 Vulkan） ----------

static void pure_plan_cases(void) {
    struct nvn_vk_bcrt_plan p;

    // A1：BC4 + RGBA16UI（8B/px，与 8B 块一一对应）→ 接受，bw/bh = ceil(w/4)。
    if (plan_accept("[A1] BC4+RGBA16UI(8B/px)", VK_FORMAT_BC4_UNORM_BLOCK,
                    VK_FORMAT_R16G16B16A16_UINT, 32, 32, 0, 0, 0, &p) == 0)
        ck_plan_fields("[A1] BC4+RGBA16UI", &p, 8, 32, 32, 0, 0, 0);

    // A2：BC4 + RGBA8（4B/px）→ 拒绝。契约允许 why 写 “cannot encode blocks”，或至少点出
    // “视图每像素字节数根本不在 8/16 字节块编码类里”这层字节原因（生产当前走后者）；严格措辞
    // “cannot encode blocks” 在下面 A2b 的“8/16 字节但块≠像素”可达分支上单独验。
    plan_reject("[A2] BC4+RGBA8(4B/px)", VK_FORMAT_BC4_UNORM_BLOCK, VK_FORMAT_R8G8B8A8_UNORM,
                32, 32, 0, 0, 0, "byte");

    // A2b：BC4 块 8B + RGBA32UI 16B/px——字节不等的“可达分支”，why 必须明说不能编码块。
    plan_reject("[A2b] BC4(8B块)+RGBA32UI(16B/px)", VK_FORMAT_BC4_UNORM_BLOCK,
                VK_FORMAT_R32G32B32A32_UINT, 32, 32, 0, 0, 0, "cannot encode blocks");

    // A3：深度格式不能当块编码视图 → 拒绝。
    plan_reject("[A3] BC4+D32_SFLOAT", VK_FORMAT_BC4_UNORM_BLOCK, VK_FORMAT_D32_SFLOAT,
                32, 32, 0, 0, 0, "depth");

    // A4：BC3（16B 块）+ RGBA32UI（16B/px）→ 接受，block_bytes=16。
    if (plan_accept("[A4] BC3+RGBA32UI(16B/px)", VK_FORMAT_BC3_UNORM_BLOCK,
                    VK_FORMAT_R32G32B32A32_UINT, 32, 32, 0, 0, 0, &p) == 0)
        ck_plan_fields("[A4] BC3+RGBA32UI", &p, 16, 32, 32, 0, 0, 0);

    // A5：非压缩底图 → 拒绝。
    plan_reject("[A5] 非压缩底图 R8_UNORM", VK_FORMAT_R8_UNORM, VK_FORMAT_R16G16B16A16_UINT,
                32, 32, 0, 0, 0, "compressed");
}

static void pure_copy_regions(void) {
    struct nvn_vk_bcrt_plan p3d, p2d, p30;
    VkBufferImageCopy c;

    // A6a/A6b：3D 底图（mip1、深度切片 2）。3D 的 layerCount 恒 1、baseArrayLayer 恒 0，
    // 片号只能走 imageOffset.z——两个方向都必须一致，否则往返会读写到别的切片。
    if (plan_accept("[A6] 3D 底图计划(level1,切片2)", VK_FORMAT_BC4_UNORM_BLOCK,
                    VK_FORMAT_R16G16B16A16_UINT, 32, 32, 1, 2, 1, &p3d) != 0)
        return;
    memset(&c, 0xAA, sizeof c);   // 先下毒：生产构造必须写满每个字段，不能依赖调用方清零
    nvn_vk_bcrt_img_to_buf(&p3d, &c);
    ck_copy_region("[A6a] 3D img_to_buf", &c, 1, 0, 2, 32, 32, 1);
    memset(&c, 0xAA, sizeof c);
    nvn_vk_bcrt_buf_to_img(&p3d, &c);
    ck_copy_region("[A6b] 3D buf_to_img", &c, 1, 0, 2, 32, 32, 1);

    // 影子两个方向：独立 2D 图（level0/layer0），extent=bw×bh=8×8、紧打包。
    memset(&c, 0xAA, sizeof c);
    nvn_vk_bcrt_buf_to_shadow(&p3d, &c);
    ck_copy_region("[A6c] 3D buf_to_shadow", &c, 0, 0, 0, 8, 8, 1);
    memset(&c, 0xAA, sizeof c);
    nvn_vk_bcrt_shadow_to_buf(&p3d, &c);
    ck_copy_region("[A6d] 3D shadow_to_buf", &c, 0, 0, 0, 8, 8, 1);

    // A6e/A6f：2D 数组底图（layer=3）→ 层号走 baseArrayLayer，z 恒 0。
    if (plan_accept("[A6] 2D 数组底图计划(layer3)", VK_FORMAT_BC4_UNORM_BLOCK,
                    VK_FORMAT_R16G16B16A16_UINT, 32, 32, 0, 3, 0, &p2d) != 0)
        return;
    memset(&c, 0xAA, sizeof c);
    nvn_vk_bcrt_img_to_buf(&p2d, &c);
    ck_copy_region("[A6e] 2D数组 img_to_buf", &c, 0, 3, 0, 32, 32, 1);
    memset(&c, 0xAA, sizeof c);
    nvn_vk_bcrt_buf_to_img(&p2d, &c);
    ck_copy_region("[A6f] 2D数组 buf_to_img", &c, 0, 3, 0, 32, 32, 1);
    memset(&c, 0xAA, sizeof c);
    nvn_vk_bcrt_buf_to_shadow(&p2d, &c);
    ck_copy_region("[A6g] 2D数组 buf_to_shadow", &c, 0, 0, 0, 8, 8, 1);
    memset(&c, 0xAA, sizeof c);
    nvn_vk_bcrt_shadow_to_buf(&p2d, &c);
    ck_copy_region("[A6h] 2D数组 shadow_to_buf", &c, 0, 0, 0, 8, 8, 1);

    // A6i/A6j：非 4 倍数尺寸（30x31）——底图 extent 用真实 mip 尺寸，影子 extent 用 ceil。
    if (plan_accept("[A6] 30x31 底图计划", VK_FORMAT_BC4_UNORM_BLOCK,
                    VK_FORMAT_R16G16B16A16_UINT, 30, 31, 0, 0, 1, &p30) != 0)
        return;
    memset(&c, 0xAA, sizeof c);
    nvn_vk_bcrt_img_to_buf(&p30, &c);
    ck_copy_region("[A6i] 30x31 img_to_buf", &c, 0, 0, 0, 30, 31, 1);
    memset(&c, 0xAA, sizeof c);
    nvn_vk_bcrt_buf_to_shadow(&p30, &c);
    ck_copy_region("[A6j] 30x31 buf_to_shadow", &c, 0, 0, 0, 8, 8, 1);
}

// ---------- C：失败路径 + 影子尺寸向上取整（不需要 Vulkan） ----------

static void pure_failure_paths(void) {
    static const struct {
        VkFormat base, view;
        const char *tag;
        const char *keyword;
    } rejects[] = {
        { VK_FORMAT_BC4_UNORM_BLOCK, VK_FORMAT_R8G8B8A8_UNORM, "[C1a] BC4+RGBA8(4B/px)", "byte" },
        { VK_FORMAT_BC4_UNORM_BLOCK, VK_FORMAT_D32_SFLOAT, "[C1b] BC4+D32_SFLOAT", "depth" },
        { VK_FORMAT_R8_UNORM, VK_FORMAT_R16G16B16A16_UINT, "[C1c] 非压缩底图", "compressed" },
        { VK_FORMAT_BC7_UNORM_BLOCK, VK_FORMAT_R16G16B16A16_UINT,
          "[C1d] BC7(16B块)+RGBA16UI(8B/px)", "cannot encode blocks" },
    };
    static const struct {
        uint32_t w, h, bw, bh;
    } ceils[] = {
        { 32, 32, 8, 8 },   // 契约点名：32→8
        { 30, 32, 8, 8 },   // 契约点名：30→8（向上取整，不是 floor）
        { 31, 32, 8, 8 },   // 契约点名：31→8
        { 1, 1, 1, 1 },     // 契约点名：1→1（不足一块算一块）
        { 5, 9, 2, 3 },     // 补充：宽高各自独立取整
    };
    char label[192];
    size_t i;

    for (i = 0; i < sizeof rejects / sizeof rejects[0]; i++)
        plan_reject(rejects[i].tag, rejects[i].base, rejects[i].view, 32, 32, 0, 0, 0,
                    rejects[i].keyword);

    for (i = 0; i < sizeof ceils / sizeof ceils[0]; i++) {
        struct nvn_vk_bcrt_plan p;
        snprintf(label, sizeof label, "[C2] %ux%u 计划", (unsigned)ceils[i].w, (unsigned)ceils[i].h);
        if (plan_accept(label, VK_FORMAT_BC4_UNORM_BLOCK, VK_FORMAT_R16G16B16A16_UINT,
                        ceils[i].w, ceils[i].h, 0, 0, 1, &p) != 0)
            continue;
        snprintf(label, sizeof label, "[C2] %ux%u 影子宽", (unsigned)ceils[i].w, (unsigned)ceils[i].h);
        ck_u32(label, p.bw, ceils[i].bw);
        snprintf(label, sizeof label, "[C2] %ux%u 影子高", (unsigned)ceils[i].w, (unsigned)ceils[i].h);
        ck_u32(label, p.bh, ceils[i].bh);
        snprintf(label, sizeof label, "[C2] %ux%u 保留底图尺寸", (unsigned)ceils[i].w, (unsigned)ceils[i].h);
        ck_u32(label, p.width, ceils[i].w);
        snprintf(label, sizeof label, "[C2] %ux%u 保留底图高度", (unsigned)ceils[i].w, (unsigned)ceils[i].h);
        ck_u32(label, p.height, ceils[i].h);
    }
}

// ---------- 真 Vulkan 小工具（device / 命令 / 图像 / 缓冲） ----------

static int make_image(VkImageType type, VkFormat fmt, uint32_t w, uint32_t h, uint32_t depth,
                      uint32_t levels, uint32_t layers, VkImageUsageFlags usage, VkImage *out,
                      VkDeviceMemory *mem_out, char *why, size_t why_size) {
    VkImageCreateInfo ci = { VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO };
    VkMemoryRequirements mr;
    VkMemoryAllocateInfo ai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO };
    uint32_t idx;
    VkResult r;

    *out = VK_NULL_HANDLE;
    *mem_out = VK_NULL_HANDLE;
    ci.imageType = type;
    ci.format = fmt;
    ci.extent = (VkExtent3D){ w, h, depth };
    ci.mipLevels = levels;
    ci.arrayLayers = layers;
    ci.samples = VK_SAMPLE_COUNT_1_BIT;
    ci.tiling = VK_IMAGE_TILING_OPTIMAL;
    ci.usage = usage;
    ci.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    ci.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    r = vkCreateImage(D.device, &ci, NULL, out);
    if (r != VK_SUCCESS) {
        snprintf(why, why_size, "vkCreateImage rc=%d", (int)r);
        return -1;
    }
    vkGetImageMemoryRequirements(D.device, *out, &mr);
    idx = s2a_vk_memory_type(&D, mr.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, NULL);
    if (idx == UINT32_MAX) {
        snprintf(why, why_size, "没有 DEVICE_LOCAL 内存类型（memoryTypeBits=0x%x）", mr.memoryTypeBits);
        vkDestroyImage(D.device, *out, NULL);
        *out = VK_NULL_HANDLE;
        return -1;
    }
    ai.allocationSize = mr.size;
    ai.memoryTypeIndex = idx;
    r = vkAllocateMemory(D.device, &ai, NULL, mem_out);
    if (r != VK_SUCCESS) {
        snprintf(why, why_size, "vkAllocateMemory rc=%d size=%llu", (int)r,
                 (unsigned long long)mr.size);
        vkDestroyImage(D.device, *out, NULL);
        *out = VK_NULL_HANDLE;
        return -1;
    }
    r = vkBindImageMemory(D.device, *out, *mem_out, 0);
    if (r != VK_SUCCESS) {
        snprintf(why, why_size, "vkBindImageMemory rc=%d", (int)r);
        vkFreeMemory(D.device, *mem_out, NULL);
        vkDestroyImage(D.device, *out, NULL);
        *out = VK_NULL_HANDLE;
        *mem_out = VK_NULL_HANDLE;
        return -1;
    }
    return 0;
}

static void drop_image(VkImage *img, VkDeviceMemory *mem) {
    if (*img) vkDestroyImage(D.device, *img, NULL);
    if (*mem) vkFreeMemory(D.device, *mem, NULL);
    *img = VK_NULL_HANDLE;
    *mem = VK_NULL_HANDLE;
}

// HOST_VISIBLE|HOST_COHERENT 的 buffer（map 读写）。契约要求：设备不支持就直接报红退出，
// 不能降级成别的内存类型偷偷跑。
static int make_host_buffer(VkDeviceSize size, VkBufferUsageFlags usage, VkBuffer *out,
                            VkDeviceMemory *mem_out, void **map_out, char *why, size_t why_size) {
    VkBufferCreateInfo ci = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO };
    VkMemoryRequirements mr;
    VkMemoryAllocateInfo ai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO };
    uint32_t idx;
    VkResult r;

    *out = VK_NULL_HANDLE;
    *mem_out = VK_NULL_HANDLE;
    *map_out = NULL;
    ci.size = size;
    ci.usage = usage;
    ci.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    r = vkCreateBuffer(D.device, &ci, NULL, out);
    if (r != VK_SUCCESS) {
        snprintf(why, why_size, "vkCreateBuffer rc=%d size=%llu", (int)r,
                 (unsigned long long)size);
        return -1;
    }
    vkGetBufferMemoryRequirements(D.device, *out, &mr);
    idx = s2a_vk_memory_type(&D, mr.memoryTypeBits,
                             VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                             NULL);
    if (idx == UINT32_MAX) {
        printf("✗ 设备内存类型：期望 存在 HOST_VISIBLE|HOST_COHERENT 的 buffer 类型（map 读写），"
               "真结果 没有（memoryTypeBits=0x%x）\n", mr.memoryTypeBits);
        fflush(stdout);
        exit(1);
    }
    ai.allocationSize = mr.size;
    ai.memoryTypeIndex = idx;
    r = vkAllocateMemory(D.device, &ai, NULL, mem_out);
    if (r != VK_SUCCESS) {
        snprintf(why, why_size, "vkAllocateMemory rc=%d", (int)r);
        vkDestroyBuffer(D.device, *out, NULL);
        *out = VK_NULL_HANDLE;
        return -1;
    }
    r = vkBindBufferMemory(D.device, *out, *mem_out, 0);
    if (r != VK_SUCCESS) {
        snprintf(why, why_size, "vkBindBufferMemory rc=%d", (int)r);
        vkFreeMemory(D.device, *mem_out, NULL);
        vkDestroyBuffer(D.device, *out, NULL);
        *out = VK_NULL_HANDLE;
        *mem_out = VK_NULL_HANDLE;
        return -1;
    }
    r = vkMapMemory(D.device, *mem_out, 0, VK_WHOLE_SIZE, 0, map_out);
    if (r != VK_SUCCESS) {
        snprintf(why, why_size, "vkMapMemory rc=%d", (int)r);
        vkFreeMemory(D.device, *mem_out, NULL);
        vkDestroyBuffer(D.device, *out, NULL);
        *out = VK_NULL_HANDLE;
        *mem_out = VK_NULL_HANDLE;
        return -1;
    }
    return 0;
}

static void free_host_buffer(VkBuffer buf, VkDeviceMemory mem, int mapped) {
    if (mapped && mem) vkUnmapMemory(D.device, mem);
    if (buf) vkDestroyBuffer(D.device, buf, NULL);
    if (mem) vkFreeMemory(D.device, mem, NULL);
}

static void image_barrier(VkCommandBuffer cmd, VkImage img, VkImageLayout from, VkImageLayout to,
                          uint32_t level0, uint32_t levels, uint32_t layers) {
    VkImageMemoryBarrier b = { VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER };
    b.oldLayout = from;
    b.newLayout = to;
    b.srcQueueFamilyIndex = b.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    b.image = img;
    b.subresourceRange = (VkImageSubresourceRange){ VK_IMAGE_ASPECT_COLOR_BIT, level0, levels, 0, layers };
    b.srcAccessMask = from == VK_IMAGE_LAYOUT_UNDEFINED
                          ? 0
                          : (VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_TRANSFER_READ_BIT |
                             VK_ACCESS_TRANSFER_WRITE_BIT | VK_ACCESS_MEMORY_WRITE_BIT);
    b.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT | VK_ACCESS_TRANSFER_READ_BIT |
                      VK_ACCESS_MEMORY_READ_BIT | VK_ACCESS_MEMORY_WRITE_BIT;
    vkCmdPipelineBarrier(cmd,
                         b.srcAccessMask ? VK_PIPELINE_STAGE_ALL_COMMANDS_BIT
                                         : VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                         VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0, 0, NULL, 0, NULL, 1, &b);
}

// 所有图像只走 GENERAL 布局；建好后转一次，后面不再换布局。
static int transition_to_general(VkImage img, uint32_t levels, uint32_t layers, const char *tag) {
    VkCommandBuffer cmd = VK_NULL_HANDLE;
    VkCommandBufferAllocateInfo ca = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO };
    VkCommandBufferBeginInfo bi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
    int ok = -1;

    ca.commandPool = D.command_pool;
    ca.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    ca.commandBufferCount = 1;
    if (vkAllocateCommandBuffers(D.device, &ca, &cmd) != VK_SUCCESS) {
        failf(tag, "期望 分配命令缓冲，真结果 vkAllocateCommandBuffers 失败");
        return -1;
    }
    if (vkBeginCommandBuffer(cmd, &bi) != VK_SUCCESS) {
        failf(tag, "期望 vkBeginCommandBuffer 成功，真结果 失败");
        vkFreeCommandBuffers(D.device, D.command_pool, 1, &cmd);
        return -1;
    }
    image_barrier(cmd, img, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_GENERAL, 0, levels, layers);
    if (vkEndCommandBuffer(cmd) != VK_SUCCESS) {
        failf(tag, "期望 vkEndCommandBuffer 成功，真结果 失败");
    } else {
        VkFenceCreateInfo fi = { VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
        VkFence fence = VK_NULL_HANDLE;
        VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO };
        si.commandBufferCount = 1;
        si.pCommandBuffers = &cmd;
        if (vkCreateFence(D.device, &fi, NULL, &fence) != VK_SUCCESS) {
            failf(tag, "期望 vkCreateFence 成功，真结果 失败");
        } else {
            VkResult r = vkQueueSubmit(D.queue, 1, &si, fence);
            if (r != VK_SUCCESS) {
                failf(tag, "期望 vkQueueSubmit 成功，真结果 rc=%d", (int)r);
            } else if (vkWaitForFences(D.device, 1, &fence, VK_TRUE, 5000000000ull) != VK_SUCCESS) {
                failf(tag, "期望 栅栏 5s 内触发，真结果 超时");
            } else {
                ok = 0;
            }
            vkDestroyFence(D.device, fence, NULL);
        }
    }
    vkFreeCommandBuffers(D.device, D.command_pool, 1, &cmd);
    return ok;
}

// 执行一段录好的命令：提交 + 等栅栏（成功返回 0）。
static int run_cb(VkCommandBuffer cmd, const char *tag) {
    VkFenceCreateInfo fi = { VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
    VkFence fence = VK_NULL_HANDLE;
    VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO };
    VkResult r;
    int ok = -1;

    si.commandBufferCount = 1;
    si.pCommandBuffers = &cmd;
    r = vkCreateFence(D.device, &fi, NULL, &fence);
    if (r != VK_SUCCESS) {
        failf(tag, "期望 vkCreateFence 成功，真结果 rc=%d", (int)r);
        return -1;
    }
    r = vkQueueSubmit(D.queue, 1, &si, fence);
    if (r != VK_SUCCESS) {
        failf(tag, "期望 vkQueueSubmit 成功，真结果 rc=%d", (int)r);
    } else if (vkWaitForFences(D.device, 1, &fence, VK_TRUE, 5000000000ull) != VK_SUCCESS) {
        failf(tag, "期望 栅栏 5s 内触发，真结果 超时");
    } else {
        ok = 0;
    }
    vkDestroyFence(D.device, fence, NULL);
    return ok;
}

static VkCommandBuffer begin_cb(const char *tag) {
    VkCommandBufferAllocateInfo ca = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO };
    VkCommandBufferBeginInfo bi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
    VkCommandBuffer cmd = VK_NULL_HANDLE;

    ca.commandPool = D.command_pool;
    ca.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    ca.commandBufferCount = 1;
    if (vkAllocateCommandBuffers(D.device, &ca, &cmd) != VK_SUCCESS) {
        failf(tag, "期望 分配命令缓冲，真结果 vkAllocateCommandBuffers 失败");
        return VK_NULL_HANDLE;
    }
    if (vkBeginCommandBuffer(cmd, &bi) != VK_SUCCESS) {
        failf(tag, "期望 vkBeginCommandBuffer 成功，真结果 失败");
        vkFreeCommandBuffers(D.device, D.command_pool, 1, &cmd);
        return VK_NULL_HANDLE;
    }
    return cmd;
}

// 上传：host 字节 → HOST_COHERENT buffer → 图像（GENERAL）。region 由生产 nvn_vk_bcrt_* 构造；
// 这里只录 vkCmdCopyBufferToImage，不做任何格式/行距换算。
static int upload_region(VkImage img, const VkBufferImageCopy *region, const void *src, size_t bytes,
                         const char *tag) {
    VkBuffer buf = VK_NULL_HANDLE;
    VkDeviceMemory mem = VK_NULL_HANDLE;
    void *map = NULL;
    VkCommandBuffer cmd;
    VkBufferMemoryBarrier bb = { VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER };
    char why[192] = "";
    int ok;

    if (make_host_buffer((VkDeviceSize)bytes, VK_BUFFER_USAGE_TRANSFER_SRC_BIT, &buf, &mem, &map,
                         why, sizeof why) != 0) {
        failf(tag, "期望 建 HOST_VISIBLE|HOST_COHERENT 上传 buffer，真结果 %s", why);
        return -1;
    }
    memcpy(map, src, bytes);
    cmd = begin_cb(tag);
    if (cmd == VK_NULL_HANDLE) {
        free_host_buffer(buf, mem, 1);
        return -1;
    }
    bb.srcAccessMask = VK_ACCESS_HOST_WRITE_BIT;
    bb.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
    bb.srcQueueFamilyIndex = bb.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    bb.buffer = buf;
    bb.offset = 0;
    bb.size = VK_WHOLE_SIZE;
    vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_HOST_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL,
                         1, &bb, 0, NULL);
    vkCmdCopyBufferToImage(cmd, buf, img, VK_IMAGE_LAYOUT_GENERAL, 1, region);
    {
        VkResult end_rc = vkEndCommandBuffer(cmd);
        if (end_rc != VK_SUCCESS) {
            failf(tag, "期望 vkEndCommandBuffer 成功，真结果 VkResult=%d", (int)end_rc);
            ok = -1;
        } else {
            ok = run_cb(cmd, tag);
        }
    }
    vkFreeCommandBuffers(D.device, D.command_pool, 1, &cmd);
    free_host_buffer(buf, mem, 1);
    return ok;
}

// 读回：图像（GENERAL）→ buffer → host 字节；只录 vkCmdCopyImageToBuffer。
static int download_region(VkImage img, const VkBufferImageCopy *region, void *dst, size_t bytes,
                           const char *tag) {
    VkBuffer buf = VK_NULL_HANDLE;
    VkDeviceMemory mem = VK_NULL_HANDLE;
    void *map = NULL;
    VkCommandBuffer cmd;
    VkBufferMemoryBarrier bb = { VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER };
    char why[192] = "";
    int ok;

    if (make_host_buffer((VkDeviceSize)bytes, VK_BUFFER_USAGE_TRANSFER_DST_BIT, &buf, &mem, &map,
                         why, sizeof why) != 0) {
        failf(tag, "期望 建 HOST_VISIBLE|HOST_COHERENT 读回 buffer，真结果 %s", why);
        return -1;
    }
    cmd = begin_cb(tag);
    if (cmd == VK_NULL_HANDLE) {
        free_host_buffer(buf, mem, 1);
        return -1;
    }
    vkCmdCopyImageToBuffer(cmd, img, VK_IMAGE_LAYOUT_GENERAL, buf, 1, region);
    bb.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    bb.dstAccessMask = VK_ACCESS_HOST_READ_BIT;
    bb.srcQueueFamilyIndex = bb.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    bb.buffer = buf;
    bb.offset = 0;
    bb.size = VK_WHOLE_SIZE;
    vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 0, NULL,
                         1, &bb, 0, NULL);
    {
        VkResult end_rc = vkEndCommandBuffer(cmd);
        if (end_rc != VK_SUCCESS) {
            failf(tag, "期望 vkEndCommandBuffer 成功，真结果 VkResult=%d", (int)end_rc);
            ok = -1;
        } else {
            ok = run_cb(cmd, tag);
        }
    }
    if (ok == 0) memcpy(dst, map, bytes);
    vkFreeCommandBuffers(D.device, D.command_pool, 1, &cmd);
    free_host_buffer(buf, mem, 1);
    return ok;
}

// 字节模式：同一起点/席位的调用必须可复现；salt 不同则首字节不同（不同平面/层/新材料能区分）。
static void fill_pattern(uint8_t *out, size_t n, uint32_t salt) {
    size_t i;
    for (i = 0; i < n; i++)
        out[i] = (uint8_t)((salt * 37u + (uint32_t)i * 29u + ((uint32_t)i >> 3) * 11u + 7u) & 0xFFu);
}

// “新材料”字节模式：刻意不是像素化数据——若往返路径偷偷做格式转换/重编码，字节会对不回去。
static void fill_fresh(uint8_t *out, size_t n, uint32_t salt) {
    size_t i;
    for (i = 0; i < n; i++)
        out[i] = (uint8_t)((0xFFu - ((salt * 53u + (uint32_t)i * 97u + 13u) & 0xFFu)) & 0xFFu);
}

static uint8_t *alloc_bytes(size_t n, const char *tag) {
    uint8_t *p = malloc(n);
    if (!p) failf(tag, "期望 分配 %zu 字节，真结果 malloc 失败", n);
    return p;
}

// ---------- B7：3D BC4 32x32x4 深度切片经影子往返 ----------

static void case_roundtrip_3d(void) {
    enum { W = 32, H = 32, DEPTH = 4 };
    const VkImageUsageFlags base_usage = VK_IMAGE_USAGE_SAMPLED_BIT |
                                         VK_IMAGE_USAGE_TRANSFER_SRC_BIT |
                                         VK_IMAGE_USAGE_TRANSFER_DST_BIT;
    const VkImageUsageFlags shadow_usage = VK_IMAGE_USAGE_SAMPLED_BIT |
                                           VK_IMAGE_USAGE_TRANSFER_SRC_BIT |
                                           VK_IMAGE_USAGE_TRANSFER_DST_BIT |
                                           VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
    char why[256] = "";
    struct nvn_vk_bcrt_plan p_plane2, p_plane0, p_plane1, p_plane3;
    VkImage base = VK_NULL_HANDLE, shadow = VK_NULL_HANDLE;
    VkDeviceMemory base_mem = VK_NULL_HANDLE, shadow_mem = VK_NULL_HANDLE;
    uint8_t *plane[DEPTH] = { NULL, NULL, NULL, NULL };
    uint8_t *old = NULL, *shadow_read = NULL, *fresh = NULL, *mid = NULL, *back = NULL;
    uint8_t *plane_back = NULL;
    VkBufferImageCopy to_buf, to_shadow, shadow_to_buf, to_img;
    size_t n;
    uint32_t i;

    printf("… B7 3D BC4 32x32x4：plane2 → buffer → 影子(RGBA16UI 8x8) → buffer → plane2\n");

    if (plan_accept("[B7] 底图计划(level0,切片2)", VK_FORMAT_BC4_UNORM_BLOCK,
                    VK_FORMAT_R16G16B16A16_UINT, W, H, 0, 2, 1, &p_plane2) != 0)
        return;
    // 底图平面字节数 = 块行(bw*block_bytes) × 块行数(bh)；影子同字节数（视图像素字节数==块字节数）。
    n = (size_t)p_plane2.bw * p_plane2.bh * p_plane2.block_bytes;

    if (make_image(VK_IMAGE_TYPE_3D, VK_FORMAT_BC4_UNORM_BLOCK, W, H, DEPTH, 1, 1, base_usage, &base,
                   &base_mem, why, sizeof why) != 0) {
        failf("[B7] 建 3D BC4 32x32x4 图像", "期望 成功（SAMPLED|TRANSFER_SRC|TRANSFER_DST），真结果 %s", why);
        return;
    }
    if (make_image(VK_IMAGE_TYPE_2D, VK_FORMAT_R16G16B16A16_UINT, p_plane2.bw, p_plane2.bh, 1, 1, 1,
                   shadow_usage, &shadow, &shadow_mem, why, sizeof why) != 0) {
        failf("[B7] 建影子 RGBA16UI %ux%u", "期望 成功，真结果 %s",
              (unsigned)p_plane2.bw, (unsigned)p_plane2.bh, why);
        drop_image(&base, &base_mem);
        return;
    }
    if (transition_to_general(base, 1, 1, "[B7] 底图转 GENERAL") != 0 ||
        transition_to_general(shadow, 1, 1, "[B7] 影子转 GENERAL") != 0)
        goto done;

    // 4 个深度平面各填一种字节模式（plane 0/2 是硬要求，1/3 一起填，避免读未初始化内容）。
    for (i = 0; i < DEPTH; i++) {
        struct nvn_vk_bcrt_plan pi;
        VkBufferImageCopy up;
        char tag[96];
        snprintf(tag, sizeof tag, "[B7] 填 plane %u 计划", (unsigned)i);
        if (plan_accept(tag, VK_FORMAT_BC4_UNORM_BLOCK, VK_FORMAT_R16G16B16A16_UINT, W, H, 0, i, 1,
                        &pi) != 0)
            goto done;
        plane[i] = alloc_bytes(n, "[B7] 分配平面字节");
        if (!plane[i]) goto done;
        fill_pattern(plane[i], n, i + 1u);
        nvn_vk_bcrt_buf_to_img(&pi, &up);   // 生产构造：3D 用 imageOffset.z 选片
        if (upload_region(base, &up, plane[i], n, "[B7] 底图上载平面") != 0) goto done;
    }
    old = alloc_bytes(n, "[B7] 分配读回字节");
    shadow_read = alloc_bytes(n, "[B7] 分配影子读回字节");
    fresh = alloc_bytes(n, "[B7] 分配新材料字节");
    mid = alloc_bytes(n, "[B7] 分配中转字节");
    back = alloc_bytes(n, "[B7] 分配底图读回字节");
    plane_back = alloc_bytes(n, "[B7] 分配平面读回字节");
    if (!old || !shadow_read || !fresh || !mid || !back || !plane_back) goto done;

    ck_true("[B7] plane0 与 plane2 初始字节不同", memcmp(plane[0], plane[2], n) != 0,
            "两种不同的字节模式");

    // ① 底图 plane 2 → buffer（生产 img_to_buf）。
    nvn_vk_bcrt_img_to_buf(&p_plane2, &to_buf);
    if (download_region(base, &to_buf, old, n, "[B7] 底图 plane2 → buffer") != 0) goto done;
    ck_bytes("[B7] 底图 plane2 初值（image→buffer 按块字节）", old, plane[2], n);

    // ② buffer → 影子（生产 buf_to_shadow）。
    nvn_vk_bcrt_buf_to_shadow(&p_plane2, &to_shadow);
    if (upload_region(shadow, &to_shadow, old, n, "[B7] buffer → 影子") != 0) goto done;

    nvn_vk_bcrt_shadow_to_buf(&p_plane2, &shadow_to_buf);
    if (download_region(shadow, &shadow_to_buf, shadow_read, n, "[B7] 影子读回") != 0) goto done;
    ck_bytes("[B7] 底图→buffer→影子 字节一致", shadow_read, plane[2], n);

    // ③ 模拟 shader 写了影子：把 buffer 换成新材料再写回影子（即 production pass 里的附件写入）。
    fill_fresh(fresh, n, 7);
    ck_true("[B7] 新材料与旧字节不同（比较有区分度）", memcmp(fresh, old, n) != 0, "不同");
    if (upload_region(shadow, &to_shadow, fresh, n, "[B7] 模拟 shader 写影子") != 0) goto done;
    if (download_region(shadow, &shadow_to_buf, mid, n, "[B7] 影子写入后读回") != 0) goto done;
    ck_bytes("[B7] 影子写入字节", mid, fresh, n);

    // ④ 影子 → buffer → 底图 plane 2（生产 shadow_to_buf + buf_to_img）。
    nvn_vk_bcrt_buf_to_img(&p_plane2, &to_img);
    if (upload_region(base, &to_img, mid, n, "[B7] 影子→buffer→底图 plane2") != 0) goto done;

    // ⑤ 底图 plane 2 读回，必须与新材料逐字节一致。
    if (download_region(base, &to_buf, back, n, "[B7] 底图 plane2 读回") != 0) goto done;
    ck_bytes("[B7] 底图 plane2 往返后字节（期望 新材料）", back, fresh, n);

    // ⑥ plane 0/1/3 必须未被改动（3D 切片寻址不能写错片）。
    if (plan_accept("[B7] plane0 计划", VK_FORMAT_BC4_UNORM_BLOCK, VK_FORMAT_R16G16B16A16_UINT, W, H,
                    0, 0, 1, &p_plane0) != 0)
        goto done;
    if (plan_accept("[B7] plane1 计划", VK_FORMAT_BC4_UNORM_BLOCK, VK_FORMAT_R16G16B16A16_UINT, W, H,
                    0, 1, 1, &p_plane1) != 0)
        goto done;
    if (plan_accept("[B7] plane3 计划", VK_FORMAT_BC4_UNORM_BLOCK, VK_FORMAT_R16G16B16A16_UINT, W, H,
                    0, 3, 1, &p_plane3) != 0)
        goto done;
    {
        const struct {
            const struct nvn_vk_bcrt_plan *plan;
            uint32_t plane;
            const char *tag;
        } untouched[] = {
            { &p_plane0, 0, "[B7] plane 0 未被改动" },
            { &p_plane1, 1, "[B7] plane 1 未被改动" },
            { &p_plane3, 3, "[B7] plane 3 未被改动" },
        };
        for (i = 0; i < sizeof untouched / sizeof untouched[0]; i++) {
            VkBufferImageCopy read;
            nvn_vk_bcrt_img_to_buf(untouched[i].plan, &read);
            if (download_region(base, &read, plane_back, n, untouched[i].tag) != 0) goto done;
            ck_bytes(untouched[i].tag, plane_back, plane[untouched[i].plane], n);
        }
    }

done:
    for (i = 0; i < DEPTH; i++) free(plane[i]);
    free(old);
    free(shadow_read);
    free(fresh);
    free(mid);
    free(back);
    free(plane_back);
    drop_image(&shadow, &shadow_mem);
    drop_image(&base, &base_mem);
}

// ---------- B8：2D BC4 32x32（mip3、层4）只改 (mip2, layer3) ----------

static void case_roundtrip_2d_array_mip(void) {
    enum { W = 32, H = 32, MIPS = 3, LAYERS = 4, TARGET_MIP = 2, TARGET_LAYER = 3 };
    enum { TARGET_W = 8, TARGET_H = 8 };
    const VkImageUsageFlags base_usage = VK_IMAGE_USAGE_SAMPLED_BIT |
                                         VK_IMAGE_USAGE_TRANSFER_SRC_BIT |
                                         VK_IMAGE_USAGE_TRANSFER_DST_BIT;
    const VkImageUsageFlags shadow_usage = VK_IMAGE_USAGE_SAMPLED_BIT |
                                           VK_IMAGE_USAGE_TRANSFER_SRC_BIT |
                                           VK_IMAGE_USAGE_TRANSFER_DST_BIT |
                                           VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
    char why[256] = "";
    struct nvn_vk_bcrt_plan p_target;
    VkImage base = VK_NULL_HANDLE, shadow = VK_NULL_HANDLE;
    VkDeviceMemory base_mem = VK_NULL_HANDLE, shadow_mem = VK_NULL_HANDLE;
    uint8_t *mip0[LAYERS] = { NULL, NULL, NULL, NULL };
    uint8_t *mip2[LAYERS] = { NULL, NULL, NULL, NULL };
    uint8_t *old = NULL, *shadow_read = NULL, *fresh = NULL, *mid = NULL, *back = NULL;
    VkBufferImageCopy to_buf, to_shadow, shadow_to_buf, to_img;
    size_t n0, n2;
    uint32_t i;

    printf("… B8 2D BC4 32x32 mip3 层4：只改 (mip2, layer3)\n");

    if (plan_accept("[B8] 目标计划(mip2,layer3)", VK_FORMAT_BC4_UNORM_BLOCK,
                    VK_FORMAT_R16G16B16A16_UINT, TARGET_W, TARGET_H, TARGET_MIP, TARGET_LAYER, 0,
                    &p_target) != 0)
        return;
    n0 = (size_t)((W + 3) / 4) * ((H + 3) / 4) * p_target.block_bytes;  // mip0：8×8 块 ×8B = 512
    n2 = (size_t)p_target.bw * p_target.bh * p_target.block_bytes;  // mip2：2×2 块 ×8B = 32

    if (make_image(VK_IMAGE_TYPE_2D, VK_FORMAT_BC4_UNORM_BLOCK, W, H, 1, MIPS, LAYERS, base_usage,
                   &base, &base_mem, why, sizeof why) != 0) {
        failf("[B8] 建 2D BC4 32x32 mip3 层4 图像", "期望 成功，真结果 %s", why);
        return;
    }
    if (make_image(VK_IMAGE_TYPE_2D, VK_FORMAT_R16G16B16A16_UINT, p_target.bw, p_target.bh, 1, 1, 1,
                   shadow_usage, &shadow, &shadow_mem, why, sizeof why) != 0) {
        failf("[B8] 建影子 RGBA16UI %ux%u", "期望 成功，真结果 %s",
              (unsigned)p_target.bw, (unsigned)p_target.bh, why);
        drop_image(&base, &base_mem);
        return;
    }
    if (transition_to_general(base, MIPS, LAYERS, "[B8] 底图转 GENERAL") != 0 ||
        transition_to_general(shadow, 1, 1, "[B8] 影子转 GENERAL") != 0)
        goto done;

    // mip0 与 mip2 每层各填一种字节模式：往返只允许改 (mip2, layer3)。
    for (i = 0; i < LAYERS; i++) {
        struct nvn_vk_bcrt_plan pi;
        VkBufferImageCopy up;
        char tag[112];
        snprintf(tag, sizeof tag, "[B8] 填 mip0 layer%u 计划", (unsigned)i);
        if (plan_accept(tag, VK_FORMAT_BC4_UNORM_BLOCK, VK_FORMAT_R16G16B16A16_UINT, W, H, 0, i, 0,
                        &pi) != 0)
            goto done;
        mip0[i] = alloc_bytes(n0, "[B8] 分配 mip0 字节");
        if (!mip0[i]) goto done;
        fill_pattern(mip0[i], n0, 11u + i);
        nvn_vk_bcrt_buf_to_img(&pi, &up);   // 生产构造：2D 数组用 baseArrayLayer
        if (upload_region(base, &up, mip0[i], n0, "[B8] 底图上载 mip0") != 0) goto done;

        snprintf(tag, sizeof tag, "[B8] 填 mip2 layer%u 计划", (unsigned)i);
        if (plan_accept(tag, VK_FORMAT_BC4_UNORM_BLOCK, VK_FORMAT_R16G16B16A16_UINT, TARGET_W,
                        TARGET_H, TARGET_MIP, i, 0, &pi) != 0)
            goto done;
        mip2[i] = alloc_bytes(n2, "[B8] 分配 mip2 字节");
        if (!mip2[i]) goto done;
        fill_pattern(mip2[i], n2, 21u + i);
        nvn_vk_bcrt_buf_to_img(&pi, &up);
        if (upload_region(base, &up, mip2[i], n2, "[B8] 底图上载 mip2") != 0) goto done;
    }
    old = alloc_bytes(n2, "[B8] 分配读回字节");
    shadow_read = alloc_bytes(n2, "[B8] 分配影子读回字节");
    fresh = alloc_bytes(n2, "[B8] 分配新材料字节");
    mid = alloc_bytes(n2, "[B8] 分配中转字节");
    back = alloc_bytes(n2, "[B8] 分配底图读回字节");
    if (!old || !shadow_read || !fresh || !mid || !back) goto done;

    // ① 底图 (mip2, layer3) → buffer。
    nvn_vk_bcrt_img_to_buf(&p_target, &to_buf);
    if (download_region(base, &to_buf, old, n2, "[B8] 底图(mip2,layer3) → buffer") != 0) goto done;
    ck_bytes("[B8] 底图 (mip2,layer3) 初值", old, mip2[TARGET_LAYER], n2);

    // ② buffer → 影子，影子读回必须一致。
    nvn_vk_bcrt_buf_to_shadow(&p_target, &to_shadow);
    if (upload_region(shadow, &to_shadow, old, n2, "[B8] buffer → 影子") != 0) goto done;
    nvn_vk_bcrt_shadow_to_buf(&p_target, &shadow_to_buf);
    if (download_region(shadow, &shadow_to_buf, shadow_read, n2, "[B8] 影子读回") != 0) goto done;
    ck_bytes("[B8] 底图→buffer→影子 字节一致", shadow_read, mip2[TARGET_LAYER], n2);

    // ③ 新材料写影子，再走 影子→buffer→底图(mip2,layer3)。
    fill_fresh(fresh, n2, 8);
    ck_true("[B8] 新材料与旧字节不同", memcmp(fresh, old, n2) != 0, "不同");
    if (upload_region(shadow, &to_shadow, fresh, n2, "[B8] 模拟 shader 写影子") != 0) goto done;
    if (download_region(shadow, &shadow_to_buf, mid, n2, "[B8] 影子写入后读回") != 0) goto done;
    ck_bytes("[B8] 影子写入字节", mid, fresh, n2);
    nvn_vk_bcrt_buf_to_img(&p_target, &to_img);
    if (upload_region(base, &to_img, mid, n2, "[B8] 影子→buffer→底图(mip2,layer3)") != 0) goto done;
    if (download_region(base, &to_buf, back, n2, "[B8] 底图(mip2,layer3) 读回") != 0) goto done;
    ck_bytes("[B8] 底图 (mip2,layer3) 往返后字节", back, fresh, n2);

    // ④ 其它子资源必须未动：(mip2,layer0)、(mip0,layer3)、(mip0,layer0)。
    {
        struct nvn_vk_bcrt_plan pm2l0, pm0l3, pm0l0;
        VkBufferImageCopy read;
        uint8_t *tmp;
        if (plan_accept("[B8] (mip2,layer0) 计划", VK_FORMAT_BC4_UNORM_BLOCK,
                        VK_FORMAT_R16G16B16A16_UINT, TARGET_W, TARGET_H, TARGET_MIP, 0, 0,
                        &pm2l0) != 0 ||
            plan_accept("[B8] (mip0,layer3) 计划", VK_FORMAT_BC4_UNORM_BLOCK,
                        VK_FORMAT_R16G16B16A16_UINT, W, H, 0, TARGET_LAYER, 0, &pm0l3) != 0 ||
            plan_accept("[B8] (mip0,layer0) 计划", VK_FORMAT_BC4_UNORM_BLOCK,
                        VK_FORMAT_R16G16B16A16_UINT, W, H, 0, 0, 0, &pm0l0) != 0)
            goto done;

        tmp = alloc_bytes(n2, "[B8] 分配未动子资源读回字节");
        if (!tmp) goto done;
        nvn_vk_bcrt_img_to_buf(&pm2l0, &read);
        if (download_region(base, &read, tmp, n2, "[B8] (mip2,layer0) 读回") != 0) {
            free(tmp);
            goto done;
        }
        ck_bytes("[B8] (mip2,layer0) 未被改动", tmp, mip2[0], n2);
        free(tmp);

        tmp = alloc_bytes(n0, "[B8] 分配 mip0 读回字节");
        if (!tmp) goto done;
        nvn_vk_bcrt_img_to_buf(&pm0l3, &read);
        if (download_region(base, &read, tmp, n0, "[B8] (mip0,layer3) 读回") != 0) {
            free(tmp);
            goto done;
        }
        ck_bytes("[B8] (mip0,layer3) 未被改动", tmp, mip0[TARGET_LAYER], n0);
        free(tmp);

        tmp = alloc_bytes(n0, "[B8] 分配 mip0 layer0 读回字节");
        if (!tmp) goto done;
        nvn_vk_bcrt_img_to_buf(&pm0l0, &read);
        if (download_region(base, &read, tmp, n0, "[B8] (mip0,layer0) 读回") != 0) {
            free(tmp);
            goto done;
        }
        ck_bytes("[B8] (mip0,layer0) 未被改动", tmp, mip0[0], n0);
        free(tmp);
    }

done:
    for (i = 0; i < LAYERS; i++) {
        free(mip0[i]);
        free(mip2[i]);
    }
    free(old);
    free(shadow_read);
    free(fresh);
    free(mid);
    free(back);
    drop_image(&shadow, &shadow_mem);
    drop_image(&base, &base_mem);
}

// ---------- B9：影子直写路径（byte 搬运，不是格式转换） ----------

static void case_shadow_direct_write(void) {
    enum { W = 32, H = 32 };
    const VkImageUsageFlags base_usage = VK_IMAGE_USAGE_SAMPLED_BIT |
                                         VK_IMAGE_USAGE_TRANSFER_SRC_BIT |
                                         VK_IMAGE_USAGE_TRANSFER_DST_BIT;
    const VkImageUsageFlags shadow_usage = VK_IMAGE_USAGE_SAMPLED_BIT |
                                           VK_IMAGE_USAGE_TRANSFER_SRC_BIT |
                                           VK_IMAGE_USAGE_TRANSFER_DST_BIT |
                                           VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
    char why[256] = "";
    struct nvn_vk_bcrt_plan p;
    VkImage base = VK_NULL_HANDLE, shadow = VK_NULL_HANDLE;
    VkDeviceMemory base_mem = VK_NULL_HANDLE, shadow_mem = VK_NULL_HANDLE;
    uint8_t *old = NULL, *fresh = NULL, *mid = NULL, *back = NULL;
    VkBufferImageCopy to_buf, to_shadow, shadow_to_buf, to_img;
    size_t n;

    printf("… B9 影子直写：新字节 → 影子 → buffer → 底图，必须逐字节一致\n");

    if (plan_accept("[B9] 底图计划(2D BC4)", VK_FORMAT_BC4_UNORM_BLOCK,
                    VK_FORMAT_R16G16B16A16_UINT, W, H, 0, 0, 0, &p) != 0)
        return;
    n = (size_t)p.bw * p.bh * p.block_bytes;

    if (make_image(VK_IMAGE_TYPE_2D, VK_FORMAT_BC4_UNORM_BLOCK, W, H, 1, 1, 1, base_usage, &base,
                   &base_mem, why, sizeof why) != 0) {
        failf("[B9] 建 2D BC4 32x32 图像", "期望 成功，真结果 %s", why);
        return;
    }
    if (make_image(VK_IMAGE_TYPE_2D, VK_FORMAT_R16G16B16A16_UINT, p.bw, p.bh, 1, 1, 1, shadow_usage,
                   &shadow, &shadow_mem, why, sizeof why) != 0) {
        failf("[B9] 建影子 RGBA16UI %ux%u", "期望 成功，真结果 %s", (unsigned)p.bw, (unsigned)p.bh,
              why);
        drop_image(&base, &base_mem);
        return;
    }
    if (transition_to_general(base, 1, 1, "[B9] 底图转 GENERAL") != 0 ||
        transition_to_general(shadow, 1, 1, "[B9] 影子转 GENERAL") != 0)
        goto done;

    old = alloc_bytes(n, "[B9] 分配旧字节");
    fresh = alloc_bytes(n, "[B9] 分配新字节");
    mid = alloc_bytes(n, "[B9] 分配中转字节");
    back = alloc_bytes(n, "[B9] 分配底图读回字节");
    if (!old || !fresh || !mid || !back) goto done;

    // 底图先有旧内容；影子直写新字节后，往返必须把新字节原样带进底图。
    fill_pattern(old, n, 31);
    nvn_vk_bcrt_buf_to_img(&p, &to_img);
    if (upload_region(base, &to_img, old, n, "[B9] 底图上载旧字节") != 0) goto done;
    nvn_vk_bcrt_img_to_buf(&p, &to_buf);
    if (download_region(base, &to_buf, mid, n, "[B9] 底图旧字节读回") != 0) goto done;
    ck_bytes("[B9] 底图旧字节", mid, old, n);

    fill_fresh(fresh, n, 9);
    ck_true("[B9] 新字节与旧字节不同", memcmp(fresh, old, n) != 0, "不同");

    // ① 直接对影子做 vkCmdCopyBufferToImage 写新字节（生产 buf_to_shadow 区域）。
    nvn_vk_bcrt_buf_to_shadow(&p, &to_shadow);
    if (upload_region(shadow, &to_shadow, fresh, n, "[B9] 直写影子") != 0) goto done;
    nvn_vk_bcrt_shadow_to_buf(&p, &shadow_to_buf);
    if (download_region(shadow, &shadow_to_buf, mid, n, "[B9] 影子直写后读回") != 0) goto done;
    ck_bytes("[B9] 影子直写字节", mid, fresh, n);

    // ② 影子 → buffer → 底图（生产 shadow_to_buf + buf_to_img）。
    if (upload_region(base, &to_img, mid, n, "[B9] 影子→buffer→底图") != 0) goto done;
    if (download_region(base, &to_buf, back, n, "[B9] 底图读回") != 0) goto done;
    ck_bytes("[B9] 影子直写后底图字节", back, fresh, n);

done:
    free(old);
    free(fresh);
    free(mid);
    free(back);
    drop_image(&shadow, &shadow_mem);
    drop_image(&base, &base_mem);
}

// ---------- 设备能力准入：缺了就明确报红退出（不降级、不静默跳过） ----------

static void require_format(VkFormat fmt, VkFormatFeatureFlags want, const char *tag) {
    VkFormatProperties fp;
    memset(&fp, 0, sizeof fp);
    vkGetPhysicalDeviceFormatProperties(D.physical, fmt, &fp);
    if ((fp.optimalTilingFeatures & want) != want) {
        printf("✗ %s：期望 optimalTilingFeatures 含 0x%08x，真结果 0x%08x\n", tag,
               (unsigned)want, (unsigned)fp.optimalTilingFeatures);
        fflush(stdout);
        exit(1);
    }
}

int main(void) {
    char why[256] = "";
    const VkFormatFeatureFlags transfer =
        VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT | VK_FORMAT_FEATURE_TRANSFER_SRC_BIT |
        VK_FORMAT_FEATURE_TRANSFER_DST_BIT;

    // A + C 不需要 Vulkan，先跑：判定/拷贝区域/失败路径任何一条红都能单独定位。
    pure_plan_cases();
    pure_copy_regions();
    pure_failure_paths();

    printf("… B 真 Vulkan 往返（宿主 lavapipe / 真机 Adreno 同一份用例源码）\n");
    if (s2a_vk_device_create(&D, why, sizeof why)) {
        printf("✗ 设备创建：期望 建 Vulkan 设备跑字节往返，真结果 失败（%s）\n", why);
        return 1;
    }
    printf("… 设备：%s / %s\n", D.driver_name, D.driver_info);

    // 影子按生产附件用法建（RGBA16UI 当颜色附件）；BC4 底图要能采样 + 双向 transfer。
    require_format(VK_FORMAT_BC4_UNORM_BLOCK, transfer, "设备能力 BC4_UNORM（底图）");
    require_format(VK_FORMAT_R16G16B16A16_UINT,
                   transfer | VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT, "设备能力 RGBA16UI（影子）");

    case_roundtrip_3d();
    case_roundtrip_2d_array_mip();
    case_shadow_direct_write();

    (void)s2a_vk_device_destroy(&D, 0);
    if (fails) {
        printf("✗ nvn_vk_bcrt: %d 处不符（共 %d 项检查）\n", fails, checks);
        return 1;
    }
    printf("✓ nvn_vk_bcrt: 判定 / 拷贝区域 / 取整 / 3D 切片往返 / 2D 数组 mip 往返 / 影子直写 "
           "%d 项检查全部通过（真 Vulkan）\n", checks);
    return 0;
}
