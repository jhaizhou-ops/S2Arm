// 直连内容归属回归（批 A'：CPU 声明写范围账本，替代“哈希决定归属 / GOB 决定覆盖”）。
//
// 语义（本测试证明的三条）：
//   1) CPU 写整幅 → 整幅归 CPU：即使 guest 内容与旧账本相同，也必须覆盖 GPU 新内容（反例⑨）；
//   2) CPU 只写局部 → 只有该范围归 CPU：未写字节保持 GPU 内容，GOB 只是上传粒度（反例⑩⑪）；
//   3) 哈希只减少上传、不决定归属：同值发布在“已同步”范围内跳过上传（⑬）；没有声明范围解释的
//      guest 变化且图像含 GPU 内容 → fail-closed（⑭）。
// 生产接缝：FlushMappedRange → nvn_vk_texcache_mark_cpu_written_range（地址+长度）；
//           WriteTexels     → nvn_vk_texcache_mark_written_rect（level/layer/区域）。
// 先写成失败：在修前代码上 ⑨⑩（以及 ⑪–⑰ 的相关断言）会红；修后全绿；撤掉关键实现会重新变红。
//
// 打桩边界（只证这些，其余归其它批）：
//   · nvn_vk_first_draw_pass_break / first_error：只返回“完成”与空错误串（帧队列证明归批 B）。
//   · nvn_vk_session_tex：直接转发 nvn_vk_texcache_get_tex（会话壳不参与）。
//   · nvn_vk_first_draw_forget_view：空实现（本测试不建 framebuffer）。
//   · lavapipe 上 bc_decode_mask 置 0：只用 RGBA8，不覆盖 BC 解码路径。
// 不证明：Adreno/真机时序、帧队列背压（dirty_defer）、GPU 区域级写登记、3D/深度/BC 局部合并。
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <sys/mman.h>
#include <unistd.h>

#include "nvn_vk_texcache.h"
#include "nvn_vk_readback.h"
#include "nvn_vk_session.h"
#include "nvn_vk_format.h"
#include "nvn_vk_first_draw.h"
#include "nvn_deswizzle.h"
#include "nvn_dirty.h"
#include "nvn_tex.h"

// ---- 宿主桩（见文件头“打桩边界”） ----
int __android_log_print(int prio, const char *tag, const char *fmt, ...) { (void)prio; (void)tag; (void)fmt; return 0; }
int __system_property_get(const char *name, char *value) { (void)name; if (value) value[0] = 0; return 0; }
static int (*g_fault_hook)(void *addr, int is_write, void *uc);
void dm_fault_hook_register(int (*fn)(void *addr, int is_write, void *uc)) { g_fault_hook = fn; }
void dm_guest_write_prep_register(void (*fn)(void *addr, size_t len)) { (void)fn; }
static void on_sig(int sig, siginfo_t *si, void *uc) {
    if (g_fault_hook && g_fault_hook(si->si_addr, 1, uc)) return;
    signal(sig, SIG_DFL);
}
void nvn_vk_first_draw_forget_view(VkImageView view) { (void)view; }
int nvn_vk_first_draw_pass_break(int sync) { (void)sync; return 0; }
const char *nvn_vk_first_draw_first_error(void) { return ""; }
struct nvn_vk_tex *nvn_vk_session_tex(struct nvn_vk_session *s, const tex_t *t, char *why, size_t why_size) {
    return nvn_vk_texcache_get_tex(&s->textures, t, why, why_size);
}

// ---- 小工具 ----
static int fails;
#define CK(c, ...) do { if (!(c)) { fails++; printf("✗ "); printf(__VA_ARGS__); printf("\n"); fflush(stdout); } } while (0)

typedef struct { uint8_t r, g, b, a; } rgba;
#define RED   ((rgba){255, 0, 0, 255})
#define BLUE  ((rgba){0, 0, 255, 255})
#define BLACK ((rgba){0, 0, 0, 255})
#define V7    ((rgba){7, 7, 7, 255})
#define V11   ((rgba){11, 11, 11, 255})

static struct nvn_vk_session *S;

static int vk_once(struct s2a_vk_device *d, VkCommandBuffer cmd) {
    VkFenceCreateInfo fi = { VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
    VkFence f = VK_NULL_HANDLE;
    if (vkCreateFence(d->device, &fi, NULL, &f) != VK_SUCCESS) return -1;
    VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO };
    si.commandBufferCount = 1; si.pCommandBuffers = &cmd;
    int rc = -1;
    if (vkQueueSubmit(d->queue, 1, &si, f) == VK_SUCCESS && vkWaitForFences(d->device, 1, &f, VK_TRUE, 5000000000ull) == VK_SUCCESS) rc = 0;
    vkDestroyFence(d->device, f, NULL);
    return rc;
}

// 测试自己的“Finish”：等设备空闲（完成证明不是本批的证明对象，见文件头）。
static void gpu_finish(void) { vkDeviceWaitIdle(S->device.device); }

static int gpu_clear_levels(VkImage img, uint32_t levels, rgba c) {
    struct s2a_vk_device *d = &S->device;
    VkCommandBufferAllocateInfo ca = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO };
    ca.commandPool = d->command_pool; ca.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY; ca.commandBufferCount = 1;
    VkCommandBuffer cmd = VK_NULL_HANDLE;
    if (vkAllocateCommandBuffers(d->device, &ca, &cmd) != VK_SUCCESS) return -1;
    VkCommandBufferBeginInfo bi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
    vkBeginCommandBuffer(cmd, &bi);
    VkImageSubresourceRange range = { VK_IMAGE_ASPECT_COLOR_BIT, 0, levels, 0, 1 };
    VkImageMemoryBarrier b = { VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER };
    b.oldLayout = VK_IMAGE_LAYOUT_GENERAL; b.newLayout = VK_IMAGE_LAYOUT_GENERAL;
    b.srcQueueFamilyIndex = b.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    b.image = img; b.subresourceRange = range;
    b.srcAccessMask = VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_TRANSFER_READ_BIT | VK_ACCESS_TRANSFER_WRITE_BIT | VK_ACCESS_MEMORY_WRITE_BIT;
    b.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1, &b);
    VkClearColorValue cv; memset(&cv, 0, sizeof cv);
    cv.float32[0] = (float)c.r / 255.0f; cv.float32[1] = (float)c.g / 255.0f;
    cv.float32[2] = (float)c.b / 255.0f; cv.float32[3] = (float)c.a / 255.0f;
    vkCmdClearColorImage(cmd, img, VK_IMAGE_LAYOUT_GENERAL, &cv, 1, &range);
    VkImageMemoryBarrier b2 = b;
    b2.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    b2.dstAccessMask = VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_TRANSFER_READ_BIT | VK_ACCESS_TRANSFER_WRITE_BIT | VK_ACCESS_MEMORY_READ_BIT;
    vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0, 0, NULL, 0, NULL, 1, &b2);
    vkEndCommandBuffer(cmd);
    int rc = vk_once(d, cmd);
    vkFreeCommandBuffers(d->device, d->command_pool, 1, &cmd);
    return rc;
}
static int gpu_clear(VkImage img, uint32_t w, uint32_t h, rgba c) {
    (void)w; (void)h;
    return gpu_clear_levels(img, 1, c);
}

// 读图像某一级 → out 为线性紧排 RGBA8（w*h*4），就是“draw 采样到的内容”。
static int gpu_read_level(VkImage img, uint32_t w, uint32_t h, uint32_t level, uint8_t *out) {
    struct s2a_vk_device *d = &S->device;
    const size_t bytes = (size_t)w * h * 4;
    VkBufferCreateInfo bci = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO };
    bci.size = bytes; bci.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT;
    VkBuffer buf = VK_NULL_HANDLE;
    if (vkCreateBuffer(d->device, &bci, NULL, &buf) != VK_SUCCESS) return -1;
    VkMemoryRequirements mr; vkGetBufferMemoryRequirements(d->device, buf, &mr);
    VkMemoryAllocateInfo mai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO };
    mai.allocationSize = mr.size;
    mai.memoryTypeIndex = s2a_vk_memory_type(d, mr.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, NULL);
    VkDeviceMemory mem = VK_NULL_HANDLE;
    void *mapped = NULL;
    int rc = -1;
    if (mai.memoryTypeIndex == UINT32_MAX || vkAllocateMemory(d->device, &mai, NULL, &mem) != VK_SUCCESS ||
        vkBindBufferMemory(d->device, buf, mem, 0) != VK_SUCCESS ||
        vkMapMemory(d->device, mem, 0, bytes, 0, &mapped) != VK_SUCCESS) goto done;
    VkCommandBufferAllocateInfo ca = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO };
    ca.commandPool = d->command_pool; ca.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY; ca.commandBufferCount = 1;
    VkCommandBuffer cmd = VK_NULL_HANDLE;
    if (vkAllocateCommandBuffers(d->device, &ca, &cmd) != VK_SUCCESS) goto done;
    VkCommandBufferBeginInfo bi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
    vkBeginCommandBuffer(cmd, &bi);
    VkImageSubresourceRange range = { VK_IMAGE_ASPECT_COLOR_BIT, level, 1, 0, 1 };
    VkImageMemoryBarrier b = { VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER };
    b.oldLayout = VK_IMAGE_LAYOUT_GENERAL; b.newLayout = VK_IMAGE_LAYOUT_GENERAL;
    b.srcQueueFamilyIndex = b.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    b.image = img; b.subresourceRange = range;
    b.srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT | VK_ACCESS_TRANSFER_WRITE_BIT | VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | VK_ACCESS_MEMORY_WRITE_BIT;
    b.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
    vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1, &b);
    VkBufferImageCopy bc = {0};
    bc.imageSubresource = (VkImageSubresourceLayers){ VK_IMAGE_ASPECT_COLOR_BIT, level, 0, 1 };
    bc.imageExtent = (VkExtent3D){ w, h, 1 };
    vkCmdCopyImageToBuffer(cmd, img, VK_IMAGE_LAYOUT_GENERAL, buf, 1, &bc);
    VkBufferMemoryBarrier bb = { VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER };
    bb.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT; bb.dstAccessMask = VK_ACCESS_HOST_READ_BIT;
    bb.srcQueueFamilyIndex = bb.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    bb.buffer = buf; bb.size = VK_WHOLE_SIZE;
    vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 0, NULL, 1, &bb, 0, NULL);
    vkEndCommandBuffer(cmd);
    if (vk_once(d, cmd) == 0) { memcpy(out, mapped, bytes); rc = 0; }
    vkFreeCommandBuffers(d->device, d->command_pool, 1, &cmd);
done:
    if (mapped) vkUnmapMemory(d->device, mem);
    if (mem) vkFreeMemory(d->device, mem, NULL);
    vkDestroyBuffer(d->device, buf, NULL);
    return rc;
}
static int gpu_read(VkImage img, uint32_t w, uint32_t h, uint8_t *out) { return gpu_read_level(img, w, h, 0, out); }

static void fill_lin(uint8_t *lin, uint32_t w, uint32_t h, rgba c) {
    for (uint32_t i = 0; i < w * h; i++) { lin[i*4+0] = c.r; lin[i*4+1] = c.g; lin[i*4+2] = c.b; lin[i*4+3] = c.a; }
}
static void fill_rect(uint8_t *lin, uint32_t w, uint32_t x, uint32_t y, uint32_t rw, uint32_t rh, rgba c) {
    for (uint32_t yy = y; yy < y + rh; yy++) for (uint32_t xx = x; xx < x + rw; xx++) {
        uint8_t *p = lin + ((size_t)yy * w + xx) * 4;
        p[0] = c.r; p[1] = c.g; p[2] = c.b; p[3] = c.a;
    }
}
static int expect_lin(const uint8_t *lin, uint32_t w, uint32_t h, rgba fill, rgba rectc,
                      uint32_t rx, uint32_t ry, uint32_t rw, uint32_t rh, const char *what) {
    for (uint32_t y = 0; y < h; y++) for (uint32_t x = 0; x < w; x++) {
        const int in = rw && x >= rx && x < rx + rw && y >= ry && y < ry + rh;
        const rgba want = in ? rectc : fill;
        const uint8_t *p = lin + ((size_t)y * w + x) * 4;
        if (p[0] != want.r || p[1] != want.g || p[2] != want.b || p[3] != want.a) {
            printf("  %s: first mismatch at (%u,%u) got=%u,%u,%u,%u want=%u,%u,%u,%u\n", what, x, y,
                   p[0], p[1], p[2], p[3], want.r, want.g, want.b, want.a);
            return -1;
        }
    }
    return 0;
}

// 把线性内容写进 guest 存储（块线性 swizzle）；保护页会缺页 → 由 nvn_dirty 的钩子解除（0 额外配置）。
static void guest_write_level(const tex_t *t, unsigned level, const uint8_t *lin) {
    uint32_t w = t->d.width >> level ? t->d.width >> level : 1;
    (void)nvn_swizzle(&t->d, level, 0, lin, (size_t)w * 4, (void *)t->mem);
}
static void guest_write(const tex_t *t, const uint8_t *lin) { guest_write_level(t, 0, lin); }

// 只写一个像素（4 B）：按块线性地址直接戳 guest 存储，模拟游戏只写了这几个字节。
// 不重写整幅，所以“未写像素必须保持 GPU 内容”才有意义。
static int guest_poke_pixel(const tex_t *t, uint32_t x, uint32_t y, rgba c) {
    uint32_t row_bytes = 0, rows = 0, slices = 0, th = 0, td = 0, bpb = 0; uint64_t base = 0;
    if (nvn_deswizzle_geom(&t->d, 0, 0, &row_bytes, &rows, &slices, &base, &th, &td, &bpb)) return -1;
    if (!bpb || x >= t->d.width || y >= t->d.height) return -1;
    uint8_t *p = (uint8_t *)t->mem + base + nvn_bl_offset(x * bpb, y, 0, row_bytes, rows, th, td);
    p[0] = c.r; p[1] = c.g; p[2] = c.b; p[3] = c.a;
    return 0;
}

// ---- 生产接缝的模拟（这两条就是调用点给后端的精确范围）----
// FlushMappedRange(mem+off, n) → 后端地址版注册入口。
static void publish_range(tex_t *t, uint64_t off, uint64_t len) {
    nvn_vk_texcache_mark_cpu_written_range(&S->textures, (const uint8_t *)t->mem + off, len);
}
static void publish_full(tex_t *t) { publish_range(t, 0, t->L.size); }
// WriteTexels(level, layer, 区域) → 后端矩形版注册入口。
static void publish_rect(tex_t *t, unsigned level, int x, int y, int w, int h) {
    nvn_vk_texcache_mark_written_rect(&S->textures, t, level, 0, x, y, w, h, 0, 1);
}

static void tex_init_levels(tex_t *t, void *mem, uint32_t w, uint32_t h, uint32_t levels, uint64_t serial) {
    memset(t, 0, sizeof *t);
    t->magic = 0x54584554;
    t->d.target = 1; t->d.format = NVN_FORMAT_RGBA8;
    t->d.width = w; t->d.height = h; t->d.depth = 1; t->d.levels = levels;
    t->serial = serial; t->mem = mem;
    nvn_tex_layout(&t->d, &t->L);
}
static void tex_init(tex_t *t, void *mem, uint32_t w, uint32_t h, uint64_t serial) {
    tex_init_levels(t, mem, w, h, 1, serial);
}

static struct nvn_vk_tex *resolve(tex_t *t, const char *what) {
    char why[256] = "";
    struct nvn_vk_tex *tx = nvn_vk_session_tex(S, t, why, sizeof why);
    if (!tx) printf("  %s: resolve failed: %s\n", what, why[0] ? why : "(no reason)");
    return tx;
}

static int read_texels(tex_t *t, uint8_t *dst, uint32_t w, uint32_t h, const char *what) {
    NVNcopyRegion r = { 0, 0, 0, (int)w, (int)h, 1 };
    char why[320] = "";
    int rc = nvn_vk_session_read_texels(S, t, 0, 0, &r, dst, 0, 0, why, sizeof why);
    if (rc) printf("  %s: read_texels failed: %s\n", what, why);
    return rc;
}

// 全 CPU 纹理的模型：guest 黑 → 建/上传 → GPU 清红 → 完成。
static struct nvn_vk_tex *make_gpu_red(tex_t *t, uint8_t *lin, uint32_t w, uint32_t h, void *mem,
                                       uint64_t serial, const char *what) {
    tex_init(t, mem, w, h, serial);
    fill_lin(lin, w, h, BLACK); guest_write(t, lin);
    struct nvn_vk_tex *tx = resolve(t, what);
    if (!tx) return NULL;
    gpu_clear(tx->image, w, h, RED);
    nvn_vk_texcache_mark_written(&S->textures, tx->image);
    gpu_finish();
    return tx;
}

static uint64_t stat_patches(void) {
    struct nvn_vk_texcache_content_stats st; memset(&st, 0, sizeof st);
    nvn_vk_texcache_content_stats(&S->textures, &st);
    return st.patches;
}
static uint64_t stat_full_covers(void) {
    struct nvn_vk_texcache_content_stats st; memset(&st, 0, sizeof st);
    nvn_vk_texcache_content_stats(&S->textures, &st);
    return st.full_covers;
}
static uint64_t stat_skips(void) {
    struct nvn_vk_texcache_content_stats st; memset(&st, 0, sizeof st);
    nvn_vk_texcache_content_stats(&S->textures, &st);
    return st.range_skips;
}

int main(void) {
    // 缺页钩子：nvn_dirty 走真的写保护 + 真缺页（与生产同一路径）。
    struct sigaction sa; memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = on_sig; sa.sa_flags = SA_SIGINFO;
    sigaction(SIGSEGV, &sa, NULL); sigaction(SIGBUS, &sa, NULL);

    S = calloc(1, sizeof *S);
    if (!S) { printf("✗ calloc session\n"); return 1; }
    char why[256] = "";
    if (s2a_vk_device_create(&S->device, why, sizeof why)) { printf("✗ device: %s\n", why); return 1; }
    S->device.bc_decode_mask = 0;   // 本测试只用 RGBA8（见文件头打桩边界）
    if (nvn_vk_texcache_init(&S->textures, &S->device, why, sizeof why)) { printf("✗ texcache: %s\n", why); return 1; }
    S->ready = 1;

    // 安卓直连的保护块是 1 MiB（避免逐页 mprotect 切碎 AHB 映射）：本测试按同一粒度跑，
    // 用来证明“1 MiB 块脏”不被当成“纹理被 CPU 改写”。
    const size_t pg = (size_t)getpagesize();
    nvn_dirty_set_chunk_pages((uint32_t)((1u << 20) / pg));

    const uint32_t W = 128, H = 128;
    const size_t TB = (size_t)W * H * 4;                 // 64 KB
    const size_t POOL = 4u << 20;
    uint8_t *pool = mmap(NULL, POOL, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (pool == MAP_FAILED) { printf("✗ mmap pool\n"); return 1; }
    uint8_t *storage = pool + 0x10000;                   // 512 对齐、同一个 1 MiB 块内还有诱饵区
    nvn_dirty_add_range(pool, POOL);                     // 一块 4 MiB 的池（生产是 NVN 内存池）

    uint8_t *lin = malloc(TB), *got = malloc(TB), *got2 = malloc(TB);
    if (!lin || !got || !got2) { printf("✗ alloc\n"); return 1; }

    // ===== 反例①：GPU 清红 → Finish → CPU 整图写蓝（发布精确范围）→ Draw/ReadTexels 必须蓝 =====
    {
        tex_t t; fill_lin(lin, W, H, BLACK);
        struct nvn_vk_tex *tx = make_gpu_red(&t, lin, W, H, storage, 1001, "①create");
        CK(tx != NULL, "① 建纹理失败");
        if (tx) {
            CK(nvn_vk_texcache_subres_state(tx, 0, 0, 0) == NVK_SUBRES_GPU,
               "① GPU 写登记后子资源状态应为 gpu（实为 %s）", nvn_vk_texcache_subres_state_name(nvn_vk_texcache_subres_state(tx, 0, 0, 0)));

            fill_lin(lin, W, H, BLUE); guest_write(&t, lin);          // CPU 整图写蓝
            publish_full(&t);                                        // 调用点发布范围（FlushMappedRange）
            nvn_vk_texcache_mark_cpu_dirty(&S->textures, &t);        // 生产同时也会给无范围 hint（ft_flush）
            tx = resolve(&t, "①after-cpu-full");
            CK(tx != NULL, "① CPU 整图写后解析失败");
            if (tx && gpu_read(tx->image, W, H, got) == 0)
                CK(expect_lin(got, W, H, BLUE, BLUE, 0, 0, 0, 0, "①draw") == 0, "① Draw 必须看到蓝（CPU 整图覆盖）");
            if (tx)
                CK(nvn_vk_texcache_subres_state(tx, 0, 0, 0) == NVK_SUBRES_CPU,
                   "① 整图覆盖后子资源应回 cpu（实为 %s）", nvn_vk_texcache_subres_state_name(nvn_vk_texcache_subres_state(tx, 0, 0, 0)));
            if (read_texels(&t, got2, W, H, "①readtexels") == 0)
                CK(expect_lin(got2, W, H, BLUE, BLUE, 0, 0, 0, 0, "①readtexels") == 0, "① ReadTexels 必须读到蓝");
            CK(nvn_vk_texcache_read_guest_ok(&S->textures, t.serial, 0, 0, 1), "① 整图覆盖回 CPU 后读回应能直接读 guest");
        }
    }

    // ===== 反例②：GPU 清红 → CPU 只写 32x32（发布精确矩形）→ Draw/ReadTexels：蓝块 + 红底 =====
    {
        tex_t t; fill_lin(lin, W, H, BLACK);
        struct nvn_vk_tex *tx = make_gpu_red(&t, lin, W, H, pool + 0x20000, 1002, "②create");
        CK(tx != NULL, "② 建纹理失败");
        if (tx) {
            fill_lin(lin, W, H, BLACK); fill_rect(lin, W, 32, 32, 32, 32, BLUE);
            guest_write(&t, lin);
            publish_rect(&t, 0, 32, 32, 32, 32);                 // WriteTexels 接缝：精确区域
            nvn_vk_texcache_mark_cpu_dirty(&S->textures, &t);
            tx = resolve(&t, "②after-cpu-partial");
            CK(tx != NULL, "② CPU 局部写后解析失败");
            if (tx && gpu_read(tx->image, W, H, got) == 0)
                CK(expect_lin(got, W, H, RED, BLUE, 32, 32, 32, 32, "②draw") == 0, "② Draw 必须是蓝块 + 红底（GPU 内容保留）");
            if (tx)
                CK(nvn_vk_texcache_subres_state(tx, 0, 0, 0) == NVK_SUBRES_MIXED,
                   "② 局部覆盖后子资源应为 mixed（实为 %s）", nvn_vk_texcache_subres_state_name(nvn_vk_texcache_subres_state(tx, 0, 0, 0)));
            if (read_texels(&t, got2, W, H, "②readtexels") == 0)
                CK(expect_lin(got2, W, H, RED, BLUE, 32, 32, 32, 32, "②readtexels") == 0, "② ReadTexels 必须是蓝块 + 红底");
        }
    }

    // ===== 反例③：内容 7 → Draw A → 内容 11 → Draw B（A 在途 → 版本化重传）=====
    {
        tex_t t; fill_lin(lin, W, H, BLACK);
        struct nvn_vk_tex *tx = make_gpu_red(&t, lin, W, H, pool + 0x30000, 1003, "③create");
        CK(tx != NULL, "③ 建纹理失败");
        if (tx) {
            fill_lin(lin, W, H, V7); guest_write(&t, lin);           // 内容 7
            publish_full(&t);
            nvn_vk_texcache_mark_cpu_dirty(&S->textures, &t);
            struct nvn_vk_tex *a = resolve(&t, "③drawA");
            CK(a != NULL, "③ Draw A 前置解析失败");
            VkImage img_a = tx->image;
            nvn_vk_texcache_pin(a);                                  // A 在途（已录制的命令仍引用它）
            if (a && gpu_read(a->image, W, H, got) == 0)
                CK(expect_lin(got, W, H, V7, V7, 0, 0, 0, 0, "③drawA") == 0, "③ Draw A 必须看到内容 7");

            fill_lin(lin, W, H, V11); guest_write(&t, lin);          // 内容 11
            publish_full(&t);
            nvn_vk_texcache_mark_cpu_dirty(&S->textures, &t);
            struct nvn_vk_tex *b = resolve(&t, "③drawB");
            CK(b != NULL, "③ Draw B 前置解析失败");
            CK(nvn_vk_texcache_versioned(&S->textures) >= 1, "③ 在途时应走版本化重传（旧 draw 看旧版本）");
            if (b && gpu_read(b->image, W, H, got) == 0)
                CK(expect_lin(got, W, H, V11, V11, 0, 0, 0, 0, "③drawB") == 0, "③ Draw B 必须看到内容 11");
            if (a) {   // A 的图像必须仍是 7（版本化不能就地覆盖在途图像）
                CK(gpu_read(img_a, W, H, got2) == 0, "③ 旧版本图像读回失败");
                CK(expect_lin(got2, W, H, V7, V7, 0, 0, 0, 0, "③drawA-after") == 0, "③ 在途的 A 图像被改写（应仍是 7）");
            }
            if (a) nvn_vk_texcache_unpin(a);
            if (read_texels(&t, got2, W, H, "③readtexels") == 0)
                CK(expect_lin(got2, W, H, V11, V11, 0, 0, 0, 0, "③readtexels") == 0, "③ 之后 ReadTexels 必须读到内容 11");
        }
    }

    printf("---- 状态/失败路径 ----\n");
    struct nvn_vk_texcache_content_stats st0;
    memset(&st0, 0, sizeof st0);
    nvn_vk_texcache_content_stats(&S->textures, &st0);
    CK(st0.gobs_scanned > 0, "账本没有扫描过（gobs_scanned=0）");
    CK(st0.full_covers > 0, "没有出现过整子资源覆盖（full_covers=0）");
    CK(st0.patches > 0, "没有出现过局部合并（patches=0）");
    CK(st0.gpu_marks > 0, "没有 GPU 写登记（gpu_marks=0）");
    CK(st0.ledger_bytes > 0 && st0.ledger_bytes < (16u << 20), "账本内存读数不合理（ledger_bytes=%llu）", (unsigned long long)st0.ledger_bytes);
    CK(st0.ranges_published > 0 && st0.ranges_applied > 0, "声明写范围没有发布/应用记录（published=%llu applied=%llu）",
       (unsigned long long)st0.ranges_published, (unsigned long long)st0.ranges_applied);

    // ===== ④ 读回不写回 guest（dst ≠ guest 池已同步）=====
    {
        tex_t t; fill_lin(lin, W, H, BLACK);
        struct nvn_vk_tex *tx = make_gpu_red(&t, lin, W, H, pool + 0x40000, 1004, "④create");
        CK(tx != NULL, "④ 建纹理失败");
        if (tx) {
            int s0 = nvn_vk_texcache_subres_state(tx, 0, 0, 0);
            if (read_texels(&t, got, W, H, "④readtexels") == 0)
                CK(expect_lin(got, W, H, RED, RED, 0, 0, 0, 0, "④readtexels") == 0, "④ GPU 内容读回应是红");
            CK(nvn_vk_texcache_subres_state(tx, 0, 0, 0) == s0, "④ 读回改了子资源状态（读图像 ≠ guest 已同步）");
            CK(!nvn_vk_texcache_read_guest_ok(&S->textures, t.serial, 0, 0, 1), "④ 读回后 guest 仍不是事实来源");
            // 读回之后 CPU 再写一整张：必须仍然生效（读回没有把它标成已同步）
            fill_lin(lin, W, H, BLUE); guest_write(&t, lin);
            publish_full(&t);
            nvn_vk_texcache_mark_cpu_dirty(&S->textures, &t);
            tx = resolve(&t, "④after");
            if (tx && gpu_read(tx->image, W, H, got) == 0)
                CK(expect_lin(got, W, H, BLUE, BLUE, 0, 0, 0, 0, "④draw") == 0, "④ 读回后再整图写蓝必须生效");
        }
    }

    // ===== ⑤ 1 MiB 保护块只是跟踪粒度：写同块内的别的数据不算这张纹理被改写 =====
    {
        tex_t a; fill_lin(lin, W, H, BLACK);
        struct nvn_vk_tex *ta = make_gpu_red(&a, lin, W, H, pool + 0x50000, 1005, "⑤create");
        CK(ta != NULL, "⑤ 建纹理失败");
        if (ta) {
            uint64_t p0 = stat_patches(), f0 = stat_full_covers();
            volatile uint8_t *decoy = pool + 0x60000;   // 同一个 1 MiB 块里、纹理之外的字节
            *decoy = 0xA5;                              // 缺页 → 整块解除保护并推进代际
            nvn_vk_texcache_mark_cpu_dirty(&S->textures, &a);   // 通知也给了（最坏情况）
            ta = resolve(&a, "⑤after-decoy");
            CK(ta != NULL, "⑤ 解析失败");
            CK(stat_patches() == p0 && stat_full_covers() == f0,
               "⑤ 只写了同块其它数据却触发了内容同步（patches %llu→%llu, full %llu→%llu）",
               (unsigned long long)p0, (unsigned long long)stat_patches(),
               (unsigned long long)f0, (unsigned long long)stat_full_covers());
            if (ta && gpu_read(ta->image, W, H, got) == 0)
                CK(expect_lin(got, W, H, RED, RED, 0, 0, 0, 0, "⑤draw") == 0, "⑤ GPU 内容不应被 1 MiB 块脏连带改写");
        }
    }

    // ===== ⑥ 提交失败/没有完成证明：必须 fail-closed，不返回旧内容；解除后重试成功 =====
    {
        tex_t t; fill_lin(lin, W, H, BLACK);
        struct nvn_vk_tex *tx = make_gpu_red(&t, lin, W, H, pool + 0x70000, 1006, "⑥create");
        CK(tx != NULL, "⑥ 建纹理失败");
        if (tx) {
            fill_lin(lin, W, H, BLACK); fill_rect(lin, W, 32, 32, 32, 32, BLUE);
            guest_write(&t, lin);
            publish_rect(&t, 0, 32, 32, 32, 32);
            nvn_vk_texcache_mark_cpu_dirty(&S->textures, &t);
            nvn_vk_texcache_set_upload_fault(2);   // 假装提交失败
            char why6[320] = "";
            struct nvn_vk_tex *bad = nvn_vk_session_tex(S, &t, why6, sizeof why6);
            CK(bad == NULL, "⑥ 局部合并提交失败时必须返回失败（不能返回旧内容）");
            CK(why6[0] != 0, "⑥ 失败原因必须可定位（空 why）");
            nvn_vk_texcache_set_upload_fault(0);
            tx = resolve(&t, "⑥retry");
            CK(tx != NULL, "⑥ 故障解除后重试应成功");
            if (tx && gpu_read(tx->image, W, H, got) == 0)
                CK(expect_lin(got, W, H, RED, BLUE, 32, 32, 32, 32, "⑥draw") == 0, "⑥ 重试后必须是蓝块 + 红底");
        }
    }

    // ===== 反例⑨ 内容归属①：CPU 整图重写“与旧 guest 同值”，仍必须覆盖 GPU 新内容 =====
    // 哈希与旧 guest 相同 ≠ CPU 没写。声明写整幅 → 整幅归 CPU，必须先于哈希判定。
    {
        tex_t t; fill_lin(lin, W, H, BLACK);
        struct nvn_vk_tex *tx = make_gpu_red(&t, lin, W, H, pool + 0xB0000, 1010, "⑨create");
        CK(tx != NULL, "⑨ 建纹理失败");
        if (tx) {
            CK(nvn_vk_texcache_subres_state(tx, 0, 0, 0) == NVK_SUBRES_GPU,
               "⑨ GPU 写登记后子资源状态应为 gpu（实为 %s）", nvn_vk_texcache_subres_state_name(nvn_vk_texcache_subres_state(tx, 0, 0, 0)));
            fill_lin(lin, W, H, BLACK); guest_write(&t, lin);   // CPU 整图重写黑 = 与建图时 guest 同值
            publish_full(&t);
            nvn_vk_texcache_mark_cpu_dirty(&S->textures, &t);
            tx = resolve(&t, "⑨after-cpu-same-value");
            CK(tx != NULL, "⑨ CPU 同值整图重写后解析失败");
            if (tx && gpu_read(tx->image, W, H, got) == 0)
                CK(expect_lin(got, W, H, BLACK, BLACK, 0, 0, 0, 0, "⑨draw") == 0,
                   "⑨ Draw 必须看到黑（CPU 整图重写与旧 guest 同值也算写）");
            if (tx)
                CK(nvn_vk_texcache_subres_state(tx, 0, 0, 0) == NVK_SUBRES_CPU,
                   "⑨ 整幅声明后子资源应回 cpu（实为 %s）", nvn_vk_texcache_subres_state_name(nvn_vk_texcache_subres_state(tx, 0, 0, 0)));
            if (read_texels(&t, got2, W, H, "⑨readtexels") == 0)
                CK(expect_lin(got2, W, H, BLACK, BLACK, 0, 0, 0, 0, "⑨readtexels") == 0,
                   "⑨ ReadTexels 必须读到黑");
        }
    }

    // ===== 反例⑩ 内容归属②：CPU 只写一个像素，未写像素必须保持 GPU 内容 =====
    // 512 B GOB 只是上传粒度，不是覆盖粒度；未写像素不能在“整 GOB 覆盖”里被旧 guest 字节盖掉。
    {
        tex_t t; fill_lin(lin, W, H, BLACK);
        struct nvn_vk_tex *tx = make_gpu_red(&t, lin, W, H, pool + 0xC0000, 1011, "⑩create");
        CK(tx != NULL, "⑩ 建纹理失败");
        if (tx) {
            CK(guest_poke_pixel(&t, 33, 33, BLUE) == 0, "⑩ 单像素写入失败");
            publish_rect(&t, 0, 33, 33, 1, 1);               // WriteTexels 接缝：单像素
            nvn_vk_texcache_mark_cpu_dirty(&S->textures, &t);
            tx = resolve(&t, "⑩after-cpu-one-pixel");
            CK(tx != NULL, "⑩ CPU 单像素写后解析失败");
            if (tx && gpu_read(tx->image, W, H, got) == 0)
                CK(expect_lin(got, W, H, RED, BLUE, 33, 33, 1, 1, "⑩draw") == 0,
                   "⑩ Draw 必须是蓝像素 + 其余红（未写像素保持 GPU 内容）");
            if (tx)
                CK(nvn_vk_texcache_subres_state(tx, 0, 0, 0) == NVK_SUBRES_MIXED,
                   "⑩ 单像素覆盖后子资源应为 mixed（实为 %s）", nvn_vk_texcache_subres_state_name(nvn_vk_texcache_subres_state(tx, 0, 0, 0)));
            if (read_texels(&t, got2, W, H, "⑩readtexels") == 0)
                CK(expect_lin(got2, W, H, RED, BLUE, 33, 33, 1, 1, "⑩readtexels") == 0,
                   "⑩ ReadTexels 必须是蓝像素 + 其余红");
        }
    }

    // ===== ⑪ 派生：局部写入紧邻已写区域（同一 GOB 的第二个像素）=====
    {
        tex_t t; fill_lin(lin, W, H, BLACK);
        struct nvn_vk_tex *tx = make_gpu_red(&t, lin, W, H, pool + 0x120000, 1012, "⑪create");
        CK(tx != NULL, "⑪ 建纹理失败");
        if (tx) {
            CK(guest_poke_pixel(&t, 33, 33, BLUE) == 0, "⑪ 第一次单像素写入失败");
            publish_rect(&t, 0, 33, 33, 1, 1);
            nvn_vk_texcache_mark_cpu_dirty(&S->textures, &t);
            tx = resolve(&t, "⑪first");
            CK(tx != NULL, "⑪ 第一次解析失败");
            CK(guest_poke_pixel(&t, 34, 33, BLUE) == 0, "⑪ 第二次单像素写入失败");
            publish_rect(&t, 0, 34, 33, 1, 1);
            nvn_vk_texcache_mark_cpu_dirty(&S->textures, &t);
            tx = resolve(&t, "⑪second");
            CK(tx != NULL, "⑪ 第二次解析失败");
            if (tx && gpu_read(tx->image, W, H, got) == 0)
                CK(expect_lin(got, W, H, RED, BLUE, 33, 33, 2, 1, "⑪draw") == 0,
                   "⑪ Draw 必须是两个相邻蓝像素 + 其余红");
        }
    }

    // ===== ⑫ 派生：多级 mip 局部合并（mip1 补丁，mip0 保持 GPU 内容）=====
    {
        const uint32_t M1W = W / 2, M1H = H / 2;
        tex_t t; tex_init_levels(&t, pool + 0x130000, W, H, 2, 1013);
        fill_lin(lin, W, H, BLACK); guest_write_level(&t, 0, lin);
        uint8_t *lin1 = malloc((size_t)M1W * M1H * 4);
        if (!lin1) { printf("✗ ⑫ alloc\n"); return 1; }
        fill_lin(lin1, M1W, M1H, BLACK); guest_write_level(&t, 1, lin1);
        struct nvn_vk_tex *tx = resolve(&t, "⑫create");
        CK(tx != NULL, "⑫ 建纹理失败");
        if (tx) {
            gpu_clear_levels(tx->image, 2, RED);
            nvn_vk_texcache_mark_written(&S->textures, tx->image);
            gpu_finish();
            fill_lin(lin1, M1W, M1H, BLACK); fill_rect(lin1, M1W, 8, 8, 8, 8, BLUE);
            guest_write_level(&t, 1, lin1);
            publish_rect(&t, 1, 8, 8, 8, 8);
            nvn_vk_texcache_mark_cpu_dirty(&S->textures, &t);
            tx = resolve(&t, "⑫after-mip1");
            CK(tx != NULL, "⑫ mip1 局部写后解析失败");
            if (tx && gpu_read_level(tx->image, M1W, M1H, 1, got) == 0)
                CK(expect_lin(got, M1W, M1H, RED, BLUE, 8, 8, 8, 8, "⑫mip1") == 0,
                   "⑫ mip1 Draw 必须是蓝块 + 红底（未写像素保持 GPU 内容）");
            if (tx && gpu_read_level(tx->image, W, H, 0, got2) == 0)
                CK(expect_lin(got2, W, H, RED, RED, 0, 0, 0, 0, "⑫mip0") == 0,
                   "⑫ mip0 必须保持 GPU 内容（局部写不能连带改写其它级）");
        }
        free(lin1);
    }

    // ===== ⑬ 派生：已同步范围内的同值发布不得再触发上传（哈希只减少上传）=====
    {
        tex_t t; tex_init(&t, pool + 0x150000, W, H, 1014);
        fill_lin(lin, W, H, BLACK); guest_write(&t, lin);
        struct nvn_vk_tex *tx = resolve(&t, "⑬create");
        CK(tx != NULL, "⑬ 建纹理失败");
        if (tx) {
            uint64_t p0 = stat_patches(), f0 = stat_full_covers(), s0 = stat_skips();
            publish_full(&t);                                  // 同值发布（guest 没变）
            nvn_vk_texcache_mark_cpu_dirty(&S->textures, &t);
            tx = resolve(&t, "⑬same-value");
            CK(tx != NULL, "⑬ 同值发布后解析失败");
            CK(stat_patches() == p0 && stat_full_covers() == f0,
               "⑬ 已同步范围内的同值发布不得触发上传（patches %llu→%llu, full %llu→%llu）",
               (unsigned long long)p0, (unsigned long long)stat_patches(),
               (unsigned long long)f0, (unsigned long long)stat_full_covers());
            CK(stat_skips() > s0, "⑬ 同值发布应走“哈希证明未变”的跳过路径（range_skips 未增加）");
            if (tx && gpu_read(tx->image, W, H, got) == 0)
                CK(expect_lin(got, W, H, BLACK, BLACK, 0, 0, 0, 0, "⑬draw") == 0, "⑬ 内容仍必须是黑");
        }
    }

    // ===== ⑭ 派生：无声明范围 + GPU 内容 + 内容变化 → 必须 fail-closed（不返回旧内容）=====
    {
        tex_t t; fill_lin(lin, W, H, BLACK);
        struct nvn_vk_tex *tx = make_gpu_red(&t, lin, W, H, pool + 0x160000, 1015, "⑭create");
        CK(tx != NULL, "⑭ 建纹理失败");
        if (tx) {
            fill_lin(lin, W, H, BLACK); fill_rect(lin, W, 32, 32, 32, 32, BLUE);
            guest_write(&t, lin);                              // 只给 hint，不发布范围
            nvn_vk_texcache_mark_cpu_dirty(&S->textures, &t);
            char why14[320] = "";
            struct nvn_vk_tex *bad = nvn_vk_session_tex(S, &t, why14, sizeof why14);
            CK(bad == NULL, "⑭ 无声明范围 + GPU 内容时必须 fail-closed（不能返回旧内容）");
            CK(strstr(why14, "声明写范围") != NULL && strstr(why14, "无法证明内容归属") != NULL,
               "⑭ 失败原因要指出缺声明写范围/无法证明归属（实为：%s）", why14);
        }
    }

    // ===== ⑮ 顺序不变量：GPU 写晚于已发布 CPU 写 → GPU 内容胜出（pending 被作废）=====
    {
        tex_t t; tex_init(&t, pool + 0x170000, W, H, 1016);
        fill_lin(lin, W, H, BLACK); guest_write(&t, lin);
        struct nvn_vk_tex *tx = resolve(&t, "⑮create");
        CK(tx != NULL, "⑮ 建纹理失败");
        if (tx) {
            publish_full(&t);                                 // 已发布 CPU 写（未落地）
            gpu_clear(tx->image, W, H, RED);                  // 之后才录制 GPU 写
            nvn_vk_texcache_mark_written(&S->textures, tx->image);
            gpu_finish();
            tx = resolve(&t, "⑮after-gpu-newer");
            CK(tx != NULL, "⑮ GPU 写后解析失败");
            if (tx && gpu_read(tx->image, W, H, got) == 0)
                CK(expect_lin(got, W, H, RED, RED, 0, 0, 0, 0, "⑮draw") == 0,
                   "⑮ GPU 写晚于已发布 CPU 写时必须保持 GPU 内容（旧 pending 不能盖回）");
        }
    }

    // ===== ⑰ 未按块对齐的声明范围：不能只拷一部分，必须 fail-closed =====
    {
        tex_t t; fill_lin(lin, W, H, BLACK);
        struct nvn_vk_tex *tx = make_gpu_red(&t, lin, W, H, pool + 0x1A0000, 1018, "⑰create");
        CK(tx != NULL, "⑰ 建纹理失败");
        if (tx) {
            publish_range(&t, 1, 3);   // 非纹素/块边界：无法用整块拷贝表达
            char why17[320] = "";
            struct nvn_vk_tex *bad = nvn_vk_session_tex(S, &t, why17, sizeof why17);
            CK(bad == NULL, "⑰ 未按块对齐的声明范围必须 fail-closed（不能只拷一部分）");
            CK(strstr(why17, "对齐") != NULL, "⑰ 失败原因要指出对齐问题（实为：%s）", why17);
        }
    }

    // ===== ⑯ 在途 + 局部声明写 + GPU 内容：必须 fail-closed（不能返回旧内容）=====
    {
        tex_t t; fill_lin(lin, W, H, BLACK);
        struct nvn_vk_tex *tx = make_gpu_red(&t, lin, W, H, pool + 0x180000, 1017, "⑯create");
        CK(tx != NULL, "⑯ 建纹理失败");
        if (tx) {
            nvn_vk_texcache_pin(tx);
            fill_lin(lin, W, H, BLACK); fill_rect(lin, W, 32, 32, 32, 32, BLUE);
            guest_write(&t, lin);
            publish_rect(&t, 0, 32, 32, 32, 32);
            nvn_vk_texcache_mark_cpu_dirty(&S->textures, &t);
            char why16[320] = "";
            struct nvn_vk_tex *bad = nvn_vk_session_tex(S, &t, why16, sizeof why16);
            CK(bad == NULL, "⑯ 在途 + 局部声明写 + GPU 内容时必须 fail-closed（不能返回旧内容）");
            CK(strstr(why16, "in flight") != NULL, "⑯ 失败原因要指出在途/需整张覆盖（实为：%s）", why16);
            nvn_vk_texcache_unpin(tx);
        }
    }

    // ===== ⑦ 账本不可用：全 CPU 内容仍可整块重传；有 GPU 内容必须 fail-closed =====
    {
        nvn_vk_texcache_set_ledger_max_bytes(1);   // 关闭账本（模拟超上限/分配失败）
        tex_t a; tex_init(&a, pool + 0x80000, W, H, 1007);
        fill_lin(lin, W, H, BLACK); guest_write(&a, lin);
        struct nvn_vk_tex *ta = resolve(&a, "⑦create-cpu");
        CK(ta != NULL, "⑦ 建 CPU 纹理失败");
        if (ta) {
            fill_lin(lin, W, H, BLUE); guest_write(&a, lin);
            publish_full(&a);                       // 全 CPU 内容：无账本也能整张重传
            nvn_vk_texcache_mark_cpu_dirty(&S->textures, &a);
            ta = resolve(&a, "⑦cpu-after");
            CK(ta != NULL, "⑦ 全 CPU 内容在无账本时仍应能整块重传");
            if (ta && gpu_read(ta->image, W, H, got) == 0)
                CK(expect_lin(got, W, H, BLUE, BLUE, 0, 0, 0, 0, "⑦cpu") == 0, "⑦ 无账本时 CPU 整图写仍要生效");
        }
        tex_t g; tex_init(&g, pool + 0x90000, W, H, 1008);
        fill_lin(lin, W, H, BLACK); guest_write(&g, lin);
        struct nvn_vk_tex *tg = resolve(&g, "⑦create-gpu");
        CK(tg != NULL, "⑦ 建 GPU 纹理失败");
        if (tg) {
            gpu_clear(tg->image, W, H, RED);
            nvn_vk_texcache_mark_written(&S->textures, tg->image);
            gpu_finish();
            fill_lin(lin, W, H, BLACK); fill_rect(lin, W, 32, 32, 32, 32, BLUE);
            guest_write(&g, lin);
            nvn_vk_texcache_mark_cpu_dirty(&S->textures, &g);   // 无范围
            char why7[320] = "";
            struct nvn_vk_tex *bad = nvn_vk_session_tex(S, &g, why7, sizeof why7);
            CK(bad == NULL, "⑦ 无账本 + GPU 内容时必须 fail-closed（不能猜）");
            CK(strstr(why7, "无法证明内容归属") != NULL, "⑦ 失败原因要指出无法证明归属（实为：%s）", why7);
        }
        nvn_vk_texcache_set_ledger_max_bytes(0);
    }

    // ===== ⑧ 全 CPU 内容 + 在途 + 局部写：没有 GPU 内容时允许“退役+新建（整张从 guest）” =====
    {
        tex_t t; tex_init(&t, pool + 0xA0000, W, H, 1009);
        fill_lin(lin, W, H, BLACK); guest_write(&t, lin);
        struct nvn_vk_tex *tx = resolve(&t, "⑧create");
        CK(tx != NULL, "⑧ 建纹理失败");
        if (tx) {
            VkImage old = tx->image;
            nvn_vk_texcache_pin(tx);   // 已录制的 draw 仍引用它
            fill_lin(lin, W, H, BLACK); fill_rect(lin, W, 32, 32, 32, 32, BLUE);
            guest_write(&t, lin);      // 只给 hint（无声明范围）：全 CPU 内容走脏页上传路径
            nvn_vk_texcache_mark_cpu_dirty(&S->textures, &t);
            uint64_t v0 = nvn_vk_texcache_versioned(&S->textures);
            struct nvn_vk_tex *fresh = resolve(&t, "⑧after");
            CK(fresh != NULL, "⑧ 全 CPU 内容在途时也应能给出新版本（不该 fail-closed）");
            CK(nvn_vk_texcache_versioned(&S->textures) == v0 + 1, "⑧ 应走版本化重传");
            if (fresh) {
                CK(fresh->image != old, "⑧ 新版本必须是新图像");
                if (gpu_read(fresh->image, W, H, got) == 0)
                    CK(expect_lin(got, W, H, BLACK, BLUE, 32, 32, 32, 32, "⑧new") == 0, "⑧ 新版本内容必须等于 guest（黑底 + 蓝块）");
            }
            if (gpu_read(old, W, H, got2) == 0)
                CK(expect_lin(got2, W, H, BLACK, BLACK, 0, 0, 0, 0, "⑧old") == 0, "⑧ 在途旧版本必须保持旧内容");
            nvn_vk_texcache_unpin(tx);
        }
    }

    // 最终纪律：声明范围必须真的被应用过、hint 未解释必须被拒过一次。
    struct nvn_vk_texcache_content_stats st;
    memset(&st, 0, sizeof st);
    nvn_vk_texcache_content_stats(&S->textures, &st);
    CK(st.ranges_applied > 0, "声明写范围一次都没被应用（ranges_applied=0）");
    CK(st.hint_unexplained > 0, "未解释变化从未 fail-closed 过（hint_unexplained=0）");

    nvn_vk_texcache_destroy(&S->textures);
    nvn_vk_session_read_texels_release(S);
    s2a_vk_device_destroy(&S->device, 1);
    free(S); free(lin); free(got); free(got2);
    munmap(pool, POOL);
    if (fails) { printf("✗ nvn_vk_texcache_content: %d 处不符\n", fails); return 1; }
    printf("✓ nvn_vk_texcache_content: 反例①②③⑨⑩ + 派生⑪–⑰ + 状态/失败路径（④–⑧）全部通过（真 Vulkan；宿主 S 级与设备 A 级共用本用例）\n");
    return 0;
}
