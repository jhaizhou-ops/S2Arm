// C5 适配层：把共享 NVN 前端的 Metal 回放接口接到 Android Vulkan 记录 decoder。
// 首版只实现内存池登记、记录执行与生命周期；纹理/管线/呈现仍显式返回未支持。
#include "nvn_obj.h"
#include "nvn2_cmd.h"   // DM_PRIM_MESH_TASKS
#include "nvn_mtl.h"
#include "../direct/vk_device.h"
#include "../direct/vk_record.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <vulkan/vulkan.h>
void s2a_direct_fail(const char *why);

struct pool { void *mem; uint64_t size; };
static struct pool g_pools[128];
static size_t g_pool_count;
static struct s2a_vk_device g_device;
static int g_device_ready;
static int g_retire_failed;
static uint64_t g_fence = 0;

struct tex_entry { const tex_t *key; VkImage image; VkDeviceMemory memory; VkFormat format; uint32_t width, height, depth; uint64_t serial; };
static struct tex_entry g_textures[128];
static size_t g_texture_count;

struct prog_entry {
    const prog_t *key;
    VkRenderPass pass;
    VkPipeline pipeline;
    VkPipelineLayout layout;
    VkFormat format;
    uint32_t width, height;
    VkDescriptorSetLayout set_layout;
    VkDescriptorSet descriptor;
    VkSampler sampler;
    VkImageView sampled_view;
    VkDescriptorPool descriptor_pool;
    VkBuffer vertex_buffer;
};
static struct prog_entry g_programs[32];
static size_t g_program_count;
static struct prog_entry *find_program(const prog_t *key) {
    for (size_t i = 0; i < g_program_count; i++) if (g_programs[i].key == key) return &g_programs[i];
    return NULL;
}

static int ensure_device(void) {
    if (g_retire_failed) return -1;
    if (g_device_ready) return 0;
    char why[160] = "";
    if (s2a_vk_device_create(&g_device, why, sizeof why)) return -1;
    g_device_ready = 1;
    return 0;
}

static VkFormat vk_format(int nvn_format) {
    switch (nvn_format) {
    case 0x25: return VK_FORMAT_R8G8B8A8_UNORM;   // NVN_FORMAT_RGBA8
    case 0x38: return VK_FORMAT_R8G8B8A8_SRGB;    // NVN_FORMAT_RGBA8_SRGB
    case 0x27: return VK_FORMAT_R8G8B8A8_UINT;    // NVN_FORMAT_RGBA8UI
    case 0x28: return VK_FORMAT_R8G8B8A8_SINT;    // NVN_FORMAT_RGBA8I
    default: return VK_FORMAT_UNDEFINED;
    }
}

static struct tex_entry *find_texture(const tex_t *key) {
    for (size_t i = 0; i < g_texture_count; i++) if (g_textures[i].key == key) return &g_textures[i];
    return NULL;
}

static struct tex_entry *ensure_texture(const tex_t *t) {
    if (!t) return NULL;
    struct tex_entry *existing = find_texture(t);
    if (existing) return existing;
    if (g_texture_count == sizeof g_textures / sizeof g_textures[0]) return NULL;
    if (ensure_device()) return NULL;
    VkFormat format = vk_format(t->d.format);
    if (format == VK_FORMAT_UNDEFINED || !t->d.width || !t->d.height) {
        fprintf(stderr, "[nvn-adapter] unsupported texture format=%d %ux%u\n", t->d.format, t->d.width, t->d.height);
        return NULL;
    }
    VkImageCreateInfo info = {0};
    info.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    info.imageType = VK_IMAGE_TYPE_2D;
    info.format = format;
    info.extent.width = t->d.width;
    info.extent.height = t->d.height;
    info.extent.depth = 1;
    info.mipLevels = 1;
    info.arrayLayers = 1;
    info.samples = VK_SAMPLE_COUNT_1_BIT;
    info.tiling = VK_IMAGE_TILING_OPTIMAL;
    info.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT;
    info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    info.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    VkImage image = VK_NULL_HANDLE;
    if (vkCreateImage(g_device.device, &info, NULL, &image) != VK_SUCCESS) {
        fprintf(stderr, "[nvn-adapter] vkCreateImage failed\n");
        return NULL;
    }
    VkMemoryRequirements req;
    vkGetImageMemoryRequirements(g_device.device, image, &req);
    VkMemoryAllocateInfo alloc = {0};
    alloc.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    alloc.allocationSize = req.size;
    alloc.memoryTypeIndex = s2a_vk_memory_type(&g_device, req.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, NULL);
    if (alloc.memoryTypeIndex == UINT32_MAX) { vkDestroyImage(g_device.device, image, NULL); return NULL; }
    VkDeviceMemory memory = VK_NULL_HANDLE;
    if (vkAllocateMemory(g_device.device, &alloc, NULL, &memory) != VK_SUCCESS ||
        vkBindImageMemory(g_device.device, image, memory, 0) != VK_SUCCESS) return NULL;
    struct tex_entry *entry = &g_textures[g_texture_count++];
    *entry = (struct tex_entry){t, image, memory, format, t->d.width, t->d.height, 1, t->serial};
    return entry;
}

static struct pool *find_pool(uint64_t address, uint64_t bytes) {
    for (size_t i = 0; i < g_pool_count; i++) {
        uint64_t base = (uint64_t)(uintptr_t)g_pools[i].mem;
        if (address >= base && bytes <= g_pools[i].size && address - base <= g_pools[i].size - bytes)
            return &g_pools[i];
    }
    return NULL;
}
static int guest_read(void *opaque, uint64_t address, void *dst, size_t bytes) {
    (void)opaque;
    struct pool *p = find_pool(address, bytes);
    if (!p) return -1;
    memcpy(dst, (const void *)(uintptr_t)address, bytes);
    return 0;
}
static int guest_write(void *opaque, uint64_t address, const void *src, size_t bytes) {
    (void)opaque;
    struct pool *p = find_pool(address, bytes);
    if (!p) return -1;
    memcpy((void *)(uintptr_t)address, src, bytes);
    return 0;
}

void mtl_init(void) {}
void mtl_bad_draw_feat(void) {}
void mtl_vbuf_stats(uint64_t *a, uint64_t *b, uint64_t *c, uint64_t *d) { if (a)*a=0; if(b)*b=0; if(c)*c=0; if(d)*d=0; }
void mtl_set_depth_zero(int on) { (void)on; }
void mtl_set_origin_lower_left(int on) { (void)on; }
void bf_want_note(const char *key) { (void)key; }
void mtl_pool_add(const void *mem, uint64_t size) {
    if (g_pool_count < sizeof g_pools / sizeof g_pools[0]) g_pools[g_pool_count++] = (struct pool){(void *)mem, size};
}
void mtl_pool_del(const void *mem) {
    for (size_t i = 0; i < g_pool_count; i++) if (g_pools[i].mem == mem) { g_pools[i] = g_pools[--g_pool_count]; return; }
}
void mtl_alias_drop_pool(const void *pool) { (void)pool; }
int mtl_addr(uint64_t addr, uint64_t len, void **buf, uint64_t *off) {
    struct pool *p = find_pool(addr, len);
    if (!p) return 0;
    if (buf) *buf = p->mem;
    if (off) *off = addr - (uint64_t)(uintptr_t)p->mem;
    return 1;
}
/* mtl_vk_adapter.c 同口径的池区间查询（compute 间接 storage 靠它取映射余量）。 */
int s2a_vk_adapter_pool_find(uint64_t addr, uint64_t len, uint64_t *base, uint64_t *size) {
    struct pool *p = find_pool(addr, len);
    if (!p) return -1;
    if (base) *base = (uint64_t)(uintptr_t)p->mem;
    if (size) *size = p->size;
    return 0;
}
void mtl_res_counts(uint32_t tick, const char *why) { (void)tick; (void)why; }
void mtl_res_snapshot(mtl_res_count *out) { if (out) memset(out, 0, sizeof *out); }

void mtl_sub_begin(void) {}
void mtl_sub_copy(uint64_t src, uint64_t dst, uint64_t n) {
    void *a, *b; uint64_t ao, bo;
    if (mtl_addr(src, n, &a, &ao) && mtl_addr(dst, n, &b, &bo)) memmove((uint8_t *)b + bo, (uint8_t *)a + ao, n);
}
void mtl_sub_event(volatile uint32_t *val, uint32_t mode, uint32_t v) { if (val) *val = mode ? *val + v : v; }
void mtl_sub_counter(uint64_t addr, uint32_t type) { (void)addr; (void)type; }
void mtl_sub_fill(uint64_t dst, uint64_t n, uint32_t value) {
    void *p; uint64_t off;
    if (mtl_addr(dst, n, &p, &off)) for (uint64_t i = 0; i < n; i++) ((uint8_t *)p)[off + i] = (uint8_t)value;
}
uint64_t mtl_sub_commit(void) { return ++g_fence; }
uint64_t mtl_last_fence(void) { return g_fence; }
int mtl_wait(uint64_t fence, uint64_t timeout_ns) { (void)fence; (void)timeout_ns; return 1; }
void mtl_finish(void) {
    if (g_device_ready && s2a_vk_device_destroy(&g_device, 0)) {
        g_retire_failed = 1;
        return;
    }
    g_device_ready = 0;
}
void mtl_drain(void) {}
void mtl_xv_window_tex(uint64_t serial) { (void)serial; }
void *mtl_device(void) { return NULL; }
uint64_t mtl_ext_tex(void *tex) { (void)tex; return 0; }
uint64_t mtl_present_ext(uint64_t serial, double period, void *ev, uint64_t ev_val, const int crop[4]) {
    (void)serial; (void)period; (void)ev; (void)ev_val; (void)crop; return 0;
}
void mtl_present_wait(uint64_t ticket) { (void)ticket; }

void mtl_sub_index(const uint64_t *h, int n) { (void)h; (void)n; }
int nvn_frec_on(void) { return 0; }      // 帧录放只在 Metal 后端（graphics/nvn/gfx/nvn/nvn_frame_rec.inc）
void nvn_frec_submit(const uint64_t *h, int n) { (void)h; (void)n; }
void nvn_frec_present(const tex_t *t, double period, const int crop[4]) { (void)t; (void)period; (void)crop; }
void mtl_exec_rest(const uint64_t *handles, int n) { (void)handles; (void)n; }
static int prescan_draws(const uint8_t *begin, const uint8_t *end, struct s2a_replay_draw *draws, size_t *count);

void mtl_exec(const uint8_t *handle) {
    if (g_retire_failed) { s2a_direct_fail("previous Vulkan device retirement incomplete"); return; }
    if (!handle) return;
    struct pool *pool = find_pool((uint64_t)(uintptr_t)handle, 1);
    if (!pool) { s2a_direct_fail("NVN 命令句柄不在已登记的内存池内"); return; }
    if (!g_device_ready) {
        char why[160] = "";
        if (s2a_vk_device_create(&g_device, why, sizeof why)) {
            s2a_direct_fail(why);
            return;
        }
        g_device_ready = 1;
    }
    struct s2a_record_memory memory = {NULL, guest_read, guest_write};
    struct s2a_record_result result;
    struct s2a_replay_texture textures[128];
    size_t texture_count = 0;
    for (size_t i = 0; i < g_texture_count; i++)
        textures[texture_count++] = (struct s2a_replay_texture){
            g_textures[i].key, g_textures[i].image, g_textures[i].format,
            g_textures[i].width, g_textures[i].height, g_textures[i].depth, g_textures[i].serial};
    const uint8_t *begin = handle;
    const uint8_t *end = (const uint8_t *)pool->mem + pool->size;
    struct s2a_replay_draw draws[32];
    size_t draw_count = 0;
    if (prescan_draws(begin, end, draws, &draw_count)) { s2a_direct_fail("NVN draw 预扫描失败"); return; }
    int rc = s2a_record_replay(&g_device, begin, end, &memory, textures, texture_count,
                               draws, draw_count, NULL, 0, &result);
    if (rc != S2A_RECORD_OK) {
        char why[192];
        snprintf(why, sizeof why, "NVN 记录回放失败: %s (op=%u)", result.why, result.opcode);
        s2a_direct_fail(why);
    }
}
uint64_t mtl_present(const tex_t *t, double period_s, const int crop[4]) { (void)t; (void)period_s; (void)crop; return 0; }
void mtl_present_wait_ticket(uint64_t ticket) { (void)ticket; }
void mtl_present_flush(void) {}
void mtl_present_test_stall(uint64_t ns) { (void)ns; }
int mtl_display_hz(void) { return 0; }
void mtl_set_tex_pool_n(int n) { (void)n; }
void mtl_set_frame(uint64_t f) { (void)f; }
void mtl_ub_present(double iv_ms) { (void)iv_ms; }
double mtl_gpu_ms(uint64_t f) { (void)f; return 0; }
int mtl_gpu_span(uint64_t f, uint64_t *t0, uint64_t *t1) { (void)f; if(t0)*t0=0; if(t1)*t1=0; return 0; }
void mtl_stats(uint64_t *passes, uint64_t *draws) { if(passes)*passes=0; if(draws)*draws=0; }
void mtl_args_stats(uint64_t *enc, uint64_t *reuse) { if(enc)*enc=0; if(reuse)*reuse=0; }
void mtl_use_stats(uint64_t *call, uint64_t *skip) { if(call)*call=0; if(skip)*skip=0; }
uint64_t mtl_ds_omit(void) { return 0; }
uint64_t mtl_drawable_ns_take(void) { return 0; }
void mtl_bw(uint64_t *load, uint64_t *store, uint64_t *full) { if(load)*load=0; if(store)*store=0; if(full)*full=0; }
uint64_t mtl_udc_saved_bytes(void) { return 0; }
int mtl_has_window(void) { return 0; }
int mtl_fps_target(void) { return 60; }
int mtl_warm_wait(int timeout_ms) { (void)timeout_ms; return 1; }
int mtl_link_active(void) { return 0; }
int mtl_link_wait_tick(int vsyncs, uint64_t timeout_ns) { (void)vsyncs; (void)timeout_ns; return 1; }
double mtl_presented_time(uint64_t n) { (void)n; return 0; }
void mtl_tex_init(const tex_t *t) { (void)ensure_texture(t); }
void mtl_tex_release(tex_t *t) {
    if (g_retire_failed) return;
    struct tex_entry *entry = find_texture(t);
    if (!entry) return;
    if (g_device_ready) {
        vkDestroyImage(g_device.device, entry->image, NULL);
        vkFreeMemory(g_device.device, entry->memory, NULL);
    }
    *entry = g_textures[--g_texture_count];
}
void mtl_pkg_stats(uint64_t *up, uint64_t *re) { if(up)*up=0; if(re)*re=0; }
uint64_t mtl_pkg_miss(void) { return 0; }
uint64_t mtl_upload_ns_take(void) { return 0; }
uint64_t mtl_upload_gpu_ns_take(void) { return 0; }
uint64_t mtl_upload_bytes(void) { return 0; }
void mtl_create_stats(uint64_t *lib, uint64_t *pso) { if(lib)*lib=0; if(pso)*pso=0; }
void mtl_create_ns(uint64_t *lib, uint64_t *pso) { if(lib)*lib=0; if(pso)*pso=0; }
void mtl_read_texels(const tex_t *t, unsigned level, unsigned layer0, const NVNcopyRegion *r, uint8_t *dst, size_t row, size_t img) {
    (void)t; (void)level; (void)layer0; (void)r; (void)dst; (void)row; (void)img;
}
void mtl_reg_tex(int id, const tex_t *t, const view_t *v) { (void)id; (void)t; (void)v; }
// 贴图池销毁时清编号段（hle_nvn.c dpool_finalize）：安卓登记表按编号哈希、不按最大编号开表，复用的编号由新登记覆盖，这里不必清
void mtl_unreg_tex_range(int base, int n) { (void)base; (void)n; }
void mtl_tex_cpu_written(const tex_t *t) { (void)t; }
int mtl_tex_gpu_owned(uint64_t serial) { (void)serial; return 0; }
void mtl_reg_samp(int id, const samp_par *p) { (void)id; (void)p; }
void mtl_prog_release(prog_t *p) { (void)p; }

int s2a_nvn_adapter_read_texture(const tex_t *texture, uint8_t *out, size_t bytes) {
    struct tex_entry *entry = find_texture(texture);
    if (!entry || !out || !bytes || !g_device_ready || g_retire_failed) return -1;
    size_t needed = (size_t)entry->width * entry->height * 4;
    if (bytes < needed) return -1;
    VkBufferCreateInfo bi = {0};
    bi.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
    bi.size = needed; bi.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT;
    VkBuffer buffer = VK_NULL_HANDLE;
    if (vkCreateBuffer(g_device.device, &bi, NULL, &buffer) != VK_SUCCESS) return -1;
    VkMemoryRequirements req;
    vkGetBufferMemoryRequirements(g_device.device, buffer, &req);
    VkMemoryAllocateInfo ai = {0};
    ai.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    ai.allocationSize = req.size;
    ai.memoryTypeIndex = s2a_vk_memory_type(&g_device, req.memoryTypeBits,
        VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, NULL);
    VkDeviceMemory memory = VK_NULL_HANDLE;
    void *mapped = NULL;
    if (ai.memoryTypeIndex == UINT32_MAX || vkAllocateMemory(g_device.device, &ai, NULL, &memory) != VK_SUCCESS ||
        vkBindBufferMemory(g_device.device, buffer, memory, 0) != VK_SUCCESS ||
        vkMapMemory(g_device.device, memory, 0, VK_WHOLE_SIZE, 0, &mapped) != VK_SUCCESS) return -1;
    VkCommandBufferAllocateInfo ca = {0};
    ca.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    ca.commandPool = g_device.command_pool; ca.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY; ca.commandBufferCount = 1;
    VkCommandBuffer cmd = VK_NULL_HANDLE;
    vkAllocateCommandBuffers(g_device.device, &ca, &cmd);
    VkCommandBufferBeginInfo cb = {0};
    cb.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    cb.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    vkBeginCommandBuffer(cmd, &cb);
    VkBufferImageCopy region = {0};
    region.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    region.imageSubresource.layerCount = 1;
    region.imageExtent = (VkExtent3D){entry->width, entry->height, 1};
    vkCmdCopyImageToBuffer(cmd, entry->image, VK_IMAGE_LAYOUT_GENERAL, buffer, 1, &region);
    VkBufferMemoryBarrier barrier = {0};
    barrier.sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER;
    barrier.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    barrier.dstAccessMask = VK_ACCESS_HOST_READ_BIT;
    barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barrier.buffer = buffer; barrier.size = VK_WHOLE_SIZE;
    vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT,
                         0, 0, NULL, 1, &barrier, 0, NULL);
    vkEndCommandBuffer(cmd);
    VkFenceCreateInfo fi = {0};
    fi.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
    VkFence fence = VK_NULL_HANDLE;
    vkCreateFence(g_device.device, &fi, NULL, &fence);
    VkSubmitInfo si = {0};
    si.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
    si.commandBufferCount = 1; si.pCommandBuffers = &cmd;
    int rc = vkQueueSubmit(g_device.queue, 1, &si, fence) == VK_SUCCESS &&
             vkWaitForFences(g_device.device, 1, &fence, VK_TRUE, UINT64_MAX) == VK_SUCCESS ? 0 : -1;
    if (rc == 0) memcpy(out, mapped, needed);
    vkDestroyFence(g_device.device, fence, NULL);
    vkUnmapMemory(g_device.device, memory);
    vkDestroyBuffer(g_device.device, buffer, NULL);
    vkFreeMemory(g_device.device, memory, NULL);
    return rc;
}

static VkShaderModule make_module(const uint8_t *code, size_t bytes) {
    if (!code || bytes < 20 || bytes % 4) return VK_NULL_HANDLE;
    const uint32_t *words = (const uint32_t *)code;
    if (words[0] != 0x07230203 || words[1] != 0x00010300) return VK_NULL_HANDLE;
    VkShaderModuleCreateInfo info = {0};
    info.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
    info.codeSize = bytes; info.pCode = words;
    VkShaderModule module = VK_NULL_HANDLE;
    return vkCreateShaderModule(g_device.device, &info, NULL, &module) == VK_SUCCESS ? module : VK_NULL_HANDLE;
}

static int register_program_internal(const prog_t *program, const uint8_t *vs, size_t vs_bytes,
                                     const uint8_t *fs, size_t fs_bytes, VkFormat format,
                                     uint32_t width, uint32_t height, const tex_t *sampled,
                                     VkPrimitiveTopology topology, const void *vertices, size_t vertex_bytes) {
    if (!program || !vs || !fs || !width || !height || ensure_device()) return -1;
    VkAttachmentDescription color = {0};
    color.format = format; color.samples = VK_SAMPLE_COUNT_1_BIT;
    color.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR; color.storeOp = VK_ATTACHMENT_STORE_OP_STORE;
    color.stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE; color.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
    color.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED; color.finalLayout = VK_IMAGE_LAYOUT_GENERAL;
    VkAttachmentReference ref = {0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
    VkSubpassDescription sub = {0};
    sub.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS; sub.colorAttachmentCount = 1; sub.pColorAttachments = &ref;
    VkSubpassDependency deps[2] = {{0}};
    deps[0].srcSubpass = VK_SUBPASS_EXTERNAL; deps[0].dstSubpass = 0;
    deps[0].srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    deps[0].dstStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    deps[0].dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
    deps[1].srcSubpass = 0; deps[1].dstSubpass = VK_SUBPASS_EXTERNAL;
    deps[1].srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    deps[1].dstStageMask = VK_PIPELINE_STAGE_TRANSFER_BIT;
    deps[1].srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
    deps[1].dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
    VkRenderPassCreateInfo rpi = {0};
    rpi.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
    rpi.attachmentCount = 1; rpi.pAttachments = &color; rpi.subpassCount = 1; rpi.pSubpasses = &sub;
    rpi.dependencyCount = 2; rpi.pDependencies = deps;
    VkRenderPass pass = VK_NULL_HANDLE;
    if (vkCreateRenderPass(g_device.device, &rpi, NULL, &pass) != VK_SUCCESS) return -1;
    VkShaderModule vmod = make_module(vs, vs_bytes), fmod = make_module(fs, fs_bytes);
    if (!vmod || !fmod) return -1;
    VkPipelineShaderStageCreateInfo stages[2] = {{0}};
    stages[0].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[0].stage = VK_SHADER_STAGE_VERTEX_BIT; stages[0].module = vmod; stages[0].pName = "main";
    stages[1].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT; stages[1].module = fmod; stages[1].pName = "main";
    VkVertexInputBindingDescription vbind = {0, 16, VK_VERTEX_INPUT_RATE_VERTEX};
    VkVertexInputAttributeDescription vattr = {0, 0, VK_FORMAT_R32G32B32A32_SFLOAT, 0};
    VkPipelineVertexInputStateCreateInfo vin = {0};
    vin.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
    if (vertices && vertex_bytes) {
        vin.vertexBindingDescriptionCount = 1; vin.pVertexBindingDescriptions = &vbind;
        vin.vertexAttributeDescriptionCount = 1; vin.pVertexAttributeDescriptions = &vattr;
    }
    VkPipelineInputAssemblyStateCreateInfo ia = {0};
    ia.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
    ia.topology = topology;
    VkViewport vp = {0, 0, (float)width, (float)height, 0, 1};
    VkRect2D sc = {{0, 0}, {width, height}};
    VkPipelineViewportStateCreateInfo vps = {0};
    vps.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
    vps.viewportCount = 1; vps.pViewports = &vp; vps.scissorCount = 1; vps.pScissors = &sc;
    VkPipelineRasterizationStateCreateInfo rs = {0};
    rs.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
    rs.polygonMode = VK_POLYGON_MODE_FILL; rs.cullMode = VK_CULL_MODE_NONE;
    rs.frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE; rs.lineWidth = 1;
    VkPipelineMultisampleStateCreateInfo ms = {0};
    ms.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
    ms.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;
    VkPipelineColorBlendAttachmentState ba = {0};
    ba.colorWriteMask = 0xF;
    VkPipelineColorBlendStateCreateInfo cb = {0};
    cb.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
    cb.attachmentCount = 1; cb.pAttachments = &ba;
    VkDescriptorSetLayout set_layout = VK_NULL_HANDLE;
    VkDescriptorSet descriptor = VK_NULL_HANDLE;
    VkSampler sampler = VK_NULL_HANDLE;
    VkImageView sampled_view = VK_NULL_HANDLE;
    VkDescriptorPool descriptor_pool = VK_NULL_HANDLE;
    if (!sampled) {
        // C2 程序的 support buffer 固定在 set0/binding0（ResourceReservationCounts 保留 1 个 UBO）。
        VkDescriptorSetLayoutBinding binding = {0};
        binding.binding = 0; binding.descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
        binding.descriptorCount = 1; binding.stageFlags = VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT;
        VkDescriptorSetLayoutCreateInfo sli = {0};
        sli.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
        sli.bindingCount = 1; sli.pBindings = &binding;
        if (vkCreateDescriptorSetLayout(g_device.device, &sli, NULL, &set_layout) != VK_SUCCESS) return -1;
        VkDescriptorPoolSize ps = {VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1};
        VkDescriptorPoolCreateInfo dpi = {0};
        dpi.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
        dpi.maxSets = 1; dpi.poolSizeCount = 1; dpi.pPoolSizes = &ps;
        if (vkCreateDescriptorPool(g_device.device, &dpi, NULL, &descriptor_pool) != VK_SUCCESS) return -1;
        VkDescriptorSetAllocateInfo dai = {0};
        dai.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
        dai.descriptorPool = descriptor_pool; dai.descriptorSetCount = 1; dai.pSetLayouts = &set_layout;
        if (vkAllocateDescriptorSets(g_device.device, &dai, &descriptor) != VK_SUCCESS) return -1;
        VkBufferCreateInfo bi = {0};
        bi.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
        bi.size = 4096; bi.usage = VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT;
        VkBuffer support = VK_NULL_HANDLE;
        if (vkCreateBuffer(g_device.device, &bi, NULL, &support) != VK_SUCCESS) return -1;
        VkMemoryRequirements req;
        vkGetBufferMemoryRequirements(g_device.device, support, &req);
        VkMemoryAllocateInfo ai = {0};
        ai.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        ai.allocationSize = req.size;
        ai.memoryTypeIndex = s2a_vk_memory_type(&g_device, req.memoryTypeBits,
            VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, NULL);
        VkDeviceMemory memory = VK_NULL_HANDLE;
        if (ai.memoryTypeIndex == UINT32_MAX || vkAllocateMemory(g_device.device, &ai, NULL, &memory) != VK_SUCCESS ||
            vkBindBufferMemory(g_device.device, support, memory, 0) != VK_SUCCESS) return -1;
        void *support_map = NULL;
        if (vkMapMemory(g_device.device, memory, 0, VK_WHOLE_SIZE, 0, &support_map) == VK_SUCCESS) {
            memset(support_map, 0, 4096);
            ((uint32_t *)support_map)[1408 / 4] = 0x40400000u;   // s2a_point.x = 3.0（点大小）
            vkUnmapMemory(g_device.device, memory);
        }
        VkDescriptorBufferInfo dbi = {support, 0, VK_WHOLE_SIZE};
        VkWriteDescriptorSet write = {0};
        write.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        write.dstSet = descriptor; write.dstBinding = 0; write.descriptorCount = 1;
        write.descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER; write.pBufferInfo = &dbi;
        vkUpdateDescriptorSets(g_device.device, 1, &write, 0, NULL);
    }
    if (sampled) {
        struct tex_entry *te = ensure_texture(sampled);
        if (!te) return -1;
        VkDescriptorSetLayoutBinding binding = {0};
        binding.binding = 0; binding.descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        binding.descriptorCount = 1; binding.stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;
        VkDescriptorSetLayoutCreateInfo sli = {0};
        sli.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
        sli.bindingCount = 1; sli.pBindings = &binding;
        if (vkCreateDescriptorSetLayout(g_device.device, &sli, NULL, &set_layout) != VK_SUCCESS) return -1;
        VkSamplerCreateInfo sci = {0};
        sci.sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
        sci.magFilter = VK_FILTER_NEAREST; sci.minFilter = VK_FILTER_NEAREST;
        sci.mipmapMode = VK_SAMPLER_MIPMAP_MODE_NEAREST;
        sci.addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        sci.addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        sci.addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        if (vkCreateSampler(g_device.device, &sci, NULL, &sampler) != VK_SUCCESS) return -1;
        VkDescriptorPoolSize ps = {VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1};
        VkDescriptorPoolCreateInfo dpi = {0};
        dpi.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
        dpi.maxSets = 1; dpi.poolSizeCount = 1; dpi.pPoolSizes = &ps;
        if (vkCreateDescriptorPool(g_device.device, &dpi, NULL, &descriptor_pool) != VK_SUCCESS) return -1;
        VkDescriptorSetAllocateInfo dai = {0};
        dai.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
        dai.descriptorPool = descriptor_pool; dai.descriptorSetCount = 1; dai.pSetLayouts = &set_layout;
        if (vkAllocateDescriptorSets(g_device.device, &dai, &descriptor) != VK_SUCCESS) return -1;
        VkImageViewCreateInfo vci = {0};
        vci.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        vci.image = te->image; vci.viewType = VK_IMAGE_VIEW_TYPE_2D; vci.format = te->format;
        vci.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        vci.subresourceRange.levelCount = 1; vci.subresourceRange.layerCount = 1;
        if (vkCreateImageView(g_device.device, &vci, NULL, &sampled_view) != VK_SUCCESS) return -1;
        VkDescriptorImageInfo dii = {sampler, sampled_view, VK_IMAGE_LAYOUT_GENERAL};
        VkWriteDescriptorSet write = {0};
        write.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        write.dstSet = descriptor; write.dstBinding = 0; write.descriptorCount = 1;
        write.descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER; write.pImageInfo = &dii;
        vkUpdateDescriptorSets(g_device.device, 1, &write, 0, NULL);
    }
    VkBuffer vertex_buffer = VK_NULL_HANDLE;
    if (vertices && vertex_bytes) {
        VkBufferCreateInfo vbi = {0};
        vbi.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
        vbi.size = vertex_bytes; vbi.usage = VK_BUFFER_USAGE_VERTEX_BUFFER_BIT;
        if (vkCreateBuffer(g_device.device, &vbi, NULL, &vertex_buffer) != VK_SUCCESS) return -1;
        VkMemoryRequirements vreq;
        vkGetBufferMemoryRequirements(g_device.device, vertex_buffer, &vreq);
        VkMemoryAllocateInfo vai = {0};
        vai.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        vai.allocationSize = vreq.size;
        vai.memoryTypeIndex = s2a_vk_memory_type(&g_device, vreq.memoryTypeBits,
            VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, NULL);
        VkDeviceMemory vmem = VK_NULL_HANDLE;
        void *mapped = NULL;
        if (vai.memoryTypeIndex == UINT32_MAX || vkAllocateMemory(g_device.device, &vai, NULL, &vmem) != VK_SUCCESS ||
            vkBindBufferMemory(g_device.device, vertex_buffer, vmem, 0) != VK_SUCCESS ||
            vkMapMemory(g_device.device, vmem, 0, VK_WHOLE_SIZE, 0, &mapped) != VK_SUCCESS) return -1;
        memcpy(mapped, vertices, vertex_bytes);
    }
    VkPipelineLayoutCreateInfo pli = {0};
    pli.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    pli.setLayoutCount = 1;
    pli.pSetLayouts = &set_layout;
    VkPipelineLayout layout = VK_NULL_HANDLE;
    if (vkCreatePipelineLayout(g_device.device, &pli, NULL, &layout) != VK_SUCCESS) return -1;
    VkGraphicsPipelineCreateInfo gp = {0};
    gp.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
    gp.stageCount = 2; gp.pStages = stages;
    gp.pVertexInputState = &vin; gp.pInputAssemblyState = &ia; gp.pViewportState = &vps;
    gp.pRasterizationState = &rs; gp.pMultisampleState = &ms; gp.pColorBlendState = &cb;
    gp.layout = layout; gp.renderPass = pass;
    VkPipeline pipeline = VK_NULL_HANDLE;
    if (vkCreateGraphicsPipelines(g_device.device, VK_NULL_HANDLE, 1, &gp, NULL, &pipeline) != VK_SUCCESS) return -1;
    vkDestroyShaderModule(g_device.device, vmod, NULL);
    vkDestroyShaderModule(g_device.device, fmod, NULL);
    if (g_program_count == sizeof g_programs / sizeof g_programs[0]) return -1;
    g_programs[g_program_count++] = (struct prog_entry){program, pass, pipeline, layout, format, width, height,
                                                        set_layout, descriptor, sampler, sampled_view, descriptor_pool, vertex_buffer};
    return 0;
}

static int prescan_draws(const uint8_t *begin, const uint8_t *end, struct s2a_replay_draw *draws, size_t *count) {
    const uint8_t *pc = begin;
    const void *rt = NULL;
    const prog_t *program = NULL;
    *count = 0;
    while (pc && pc < end) {
        if ((size_t)(end - pc) < sizeof(op_hdr)) return -1;
        op_hdr header; memcpy(&header, pc, sizeof header);
        if (header.size < sizeof header || header.size % 8 || (size_t)(end - pc) < header.size) {
            fprintf(stderr, "[nvn-adapter] prescan header op=%u size=%u remain=%zu\n", header.op, header.size, (size_t)(end - pc));
            return -1;
        }
        const uint8_t *payload = pc + sizeof header;
        switch (header.op) {
        case OP_END: return 0;
        case OP_SET_RT: {
            p_set_rt_c compact = {0}; p_set_rt record;   // 紧凑记录（nvn_obj.h），经 set_rt_rec 还原
            if (header.size >= sizeof(op_hdr) + sizeof compact) memcpy(&compact, payload, sizeof compact);
            if (header.size < sizeof(op_hdr) + sizeof compact || header.size - sizeof(op_hdr) < set_rt_payload(&compact)) {
                fprintf(stderr, "[nvn-adapter] SET_RT short size=%u\n", header.size);
                return -1;
            }
            set_rt_rec(payload, header.size, &record);
            rt = record.n > 0 ? (const void *)record.color[0] : NULL;
            break;
        }
        case OP_BIND_PROGRAM: {
            p_bind_program_id id;
            if (header.size != sizeof(op_hdr) + sizeof id) {
                fprintf(stderr, "[nvn-adapter] BIND_PROGRAM size=%u need=%zu\n", header.size, sizeof(op_hdr) + sizeof id);
                return -1;
            }
            memcpy(&id, payload, sizeof id);
            p_bind_program record; program = bind_program_rec(&id, header.size, &record)->prog;
            break;
        }
        case OP_DRAW: {
            p_draw record;
            memset(&record, 0, sizeof record);
            if (header.size < sizeof(op_hdr) + offsetof(p_draw, ind)) {
                fprintf(stderr, "[nvn-adapter] DRAW short size=%u need=%zu\n", header.size, sizeof(op_hdr) + offsetof(p_draw, ind));
                return -1;
            }
            size_t draw_bytes = header.size - sizeof(op_hdr);
            if (draw_bytes > sizeof record) draw_bytes = sizeof record;
            memcpy(&record, payload, draw_bytes);
            if (record.ind || record.mdi_cnt || record.prim == DM_PRIM_MESH_TASKS || !program || !rt) break;   // 网格绘制（nvn2_cmd.h）：回放报不支持（vk_record.c），这里不预建
            struct prog_entry *pe = find_program(program);
            struct tex_entry *te = NULL;
            for (size_t i = 0; i < g_texture_count; i++)
                if (g_textures[i].key == rt || (g_textures[i].serial && ((const tex_t *)rt)->serial == g_textures[i].serial)) { te = &g_textures[i]; break; }
            if (!pe || !te || *count == 32) break;
            VkImageViewCreateInfo vci = {0};
            vci.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
            vci.image = te->image; vci.viewType = VK_IMAGE_VIEW_TYPE_2D; vci.format = te->format;
            vci.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
            vci.subresourceRange.levelCount = 1; vci.subresourceRange.layerCount = 1;
            VkImageView view = VK_NULL_HANDLE;
            if (vkCreateImageView(g_device.device, &vci, NULL, &view) != VK_SUCCESS) return -1;
            VkFramebufferCreateInfo fbi = {0};
            fbi.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
            fbi.renderPass = pe->pass; fbi.attachmentCount = 1; fbi.pAttachments = &view;
            fbi.width = te->width; fbi.height = te->height; fbi.layers = 1;
            VkFramebuffer fb = VK_NULL_HANDLE;
            if (vkCreateFramebuffer(g_device.device, &fbi, NULL, &fb) != VK_SUCCESS) return -1;
            draws[(*count)++] = (struct s2a_replay_draw){program, rt, pe->pipeline, pe->pass, fb,
                                                       {te->width, te->height}, pe->layout, pe->descriptor,
                                                       pe->vertex_buffer, 0};
            break;
        }
        case OP_JUMP: case OP_CALL: return -1;
        default: break;
        }
        pc += header.size;
    }
    return 0;
}

int s2a_nvn_adapter_register_program(const prog_t *program, const uint8_t *vs, size_t vs_bytes,
                                     const uint8_t *fs, size_t fs_bytes, VkFormat format,
                                     uint32_t width, uint32_t height) {
    return register_program_internal(program, vs, vs_bytes, fs, fs_bytes, format, width, height, NULL, VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, NULL, 0);
}
int s2a_nvn_adapter_register_program_textured(const prog_t *program, const uint8_t *vs, size_t vs_bytes,
                                              const uint8_t *fs, size_t fs_bytes, VkFormat format,
                                              uint32_t width, uint32_t height, const tex_t *sampled) {
    return register_program_internal(program, vs, vs_bytes, fs, fs_bytes, format, width, height, sampled, VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, NULL, 0);
}

int s2a_nvn_adapter_register_program_topology(const prog_t *program, const uint8_t *vs, size_t vs_bytes,
                                              const uint8_t *fs, size_t fs_bytes, VkFormat format,
                                              uint32_t width, uint32_t height, VkPrimitiveTopology topology) {
    return register_program_internal(program, vs, vs_bytes, fs, fs_bytes, format, width, height,
                                     NULL, topology, NULL, 0);
}

int s2a_nvn_adapter_register_program_vertex(const prog_t *program, const uint8_t *vs, size_t vs_bytes,
                                            const uint8_t *fs, size_t fs_bytes, VkFormat format,
                                            uint32_t width, uint32_t height, const void *vertices,
                                            size_t vertex_bytes) {
    return register_program_internal(program, vs, vs_bytes, fs, fs_bytes, format, width, height,
                                     NULL, VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, vertices, vertex_bytes);
}
