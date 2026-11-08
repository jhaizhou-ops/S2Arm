// vk_membuf.c 的宿主单测（fake Vulkan，确定性，不需要 GPU / Android 设备）。
//
// 为什么要有：这一层决定「显存从哪来、同步怎么保」——host import / AHB / dma-buf / 上传四选一，
// 依赖扩展是否 advertise、内存是否 HOST_COHERENT、host 指针是否对齐、错误路径是否留下半分配。
// 这些判定**不依赖驱动实现**，可以在宿主用 fake Vulkan 全覆盖；真机只负责验证“这条路径在这台设备上
// 确实可用”（selftest 的职责），不在本文件的覆盖范围。
//
// 本文件只链接生产 vk_membuf.c。s2a_vk_memory_type 的生产实现在 vk_device.c（会拖进真 Vulkan 链接），
// 这里按生产语义提供替身（见文件中部注释），不是另写一份模型。
//
// 覆盖（对应 PR #1378 维护方复核要求）：
//   1. s2a_gpu_mem_probe：字段映射（host_import / host_align / ahb / dmabuf / chosen / shared_enabled）、
//      无 device / caps 为空的拒绝、g_caps 查询。
//   2. UPLOAD 分配：句柄 / 大小 / kind / mapped / coherent；内存类型优先选 HOST_COHERENT；
//      一致内存 flush/invalidate 不真调用，非一致必须各调用一次（范围是整块）；
//      kind=NONE 落到 UPLOAD；kind=HOST_IMPORT 走 create 必须拒绝。
//   3. s2a_gpu_buf_import：未启用扩展 / vkGetDeviceProcAddr 缺失 / 指针未对齐 / 驱动拒绝 /
//      无共享内存类型五类拒绝；满足条件时成功、kind=HOST_IMPORT、cpu 就是原指针、不再 vkMapMemory。
//   4. 错误路径：vkCreateBuffer / vkAllocateMemory / vkBindBufferMemory 失败时 buf/mem 为
//      VK_NULL_HANDLE，对应 destroy/free 次数正确，无残留 live 对象。
//   5. import 参数校验：host==NULL / size==0 拒绝；驱动 memory requirements 超出导入区间拒绝
//      （否则 allocationSize 会大于实际提供的 host 区间，有越界读风险）。
//   6. destroy：UPLOAD 顺序 unmap → destroy buffer → free memory，结构清零，重复 destroy 幂等。
//   7. selftest：fake GPU 在 fence 等待时按 vkCmdCopyBuffer 记录的区间真实搬运字节，
//      CPU 写 src → GPU 拷到**另一块** dst 内存 → CPU 读 dst 校验；再用“坏拷贝”负对照证明
//      这条自检抓得到不一致（不是恒绿）。另覆盖 HOST_IMPORT 后端（自己分配对齐 host 内存再
//      import）与 vkCreateFence 失败时的清理。
//   8. s2a_gpu_mem_bench(HOST_IMPORT)：返回 >0（此前对导入后端恒失败），失败路径不留对象。
//
// fake 语义边界（真机驱动行为不在此覆盖，汇报里列为未验）：
//   - 宿主构建没有 __ANDROID__，AHB/dma-buf 分支不参与编译：caps.ahb/dmabuf 恒 0，
//     create(AHB) 退化为 UPLOAD（用例里显式记录这个宿主行为）。
//   - 内存一致性只按 VkMemoryPropertyFlags 模拟，不模拟 cache 行；非一致时只校验
//     flush/invalidate“调没调、参数对不对”，真实 cache 维护效果需要真机。
//   - vkGetDeviceProcAddr 只认 vkGetMemoryHostPointerPropertiesEXT，其他扩展名返回 NULL。
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "vk_device.h"
#include "vk_membuf.h"

// ---- 用例/断言记账 ---------------------------------------------------------
static int g_checks;
static int g_fail;
static int g_cases;
static int g_case_fail0;
static int g_case_msg_n;
static char g_case_msg[8][384];

static void case_fail(const char *file, int line, const char *expr) {
    g_fail++;
    if (g_case_msg_n < (int)(sizeof g_case_msg / sizeof g_case_msg[0]))
        snprintf(g_case_msg[g_case_msg_n++], sizeof g_case_msg[0], "%s:%d: %s", file, line, expr);
}
#define CHECK(cond) do { g_checks++; if (!(cond)) case_fail(__FILE__, __LINE__, #cond); } while (0)

static void case_begin(const char *name) {
    g_cases++;
    g_case_fail0 = g_fail;
    g_case_msg_n = 0;
    printf("  case %-38s", name);
    fflush(stdout);
}
static void case_end(void) {
    if (g_fail == g_case_fail0) {
        printf("PASS\n");
        return;
    }
    printf("FAIL\n");
    for (int i = 0; i < g_case_msg_n; i++) printf("      %s\n", g_case_msg[i]);
}

// ---- fake Vulkan -----------------------------------------------------------
// 只实现 vk_membuf.c 调到的入口。句柄是 fake 对象的地址（非空、不透明，测试里不 deref Vulkan 类型）。
// 内存模型：
//   VkDeviceMemory -> 一块 calloc 的 host 内存；host import 时直接指向被导入的 host 指针（不拷贝）。
//   VkBuffer       -> {size, usage, 绑定的 mem, 是否声明 external handleTypes}。
//   vkCmdCopyBuffer 只记录区间；vkWaitForFences（模拟 GPU 完成）才按区间真实 memcpy，
//   所以「CPU 写 src -> GPU 拷到 dst -> CPU 读 dst」里的 dst.cpu 是另一块分配，不是 src 指针的别名。
#define FAKE_MAX_BUF 16
#define FAKE_MAX_MEM 16
#define FAKE_MAX_COPY 4

enum fake_event {
    EV_CREATE_BUFFER = 1,
    EV_ALLOCATE_MEMORY,
    EV_BIND_BUFFER_MEMORY,
    EV_MAP_MEMORY,
    EV_UNMAP_MEMORY,
    EV_DESTROY_BUFFER,
    EV_FREE_MEMORY,
    EV_FLUSH,
    EV_INVALIDATE,
    EV_CMD_COPY,
    EV_SUBMIT,
    EV_WAIT,
};

struct fake_buffer {
    int live;
    VkDeviceSize size;
    VkBufferUsageFlags usage;
    int has_external_info;
    VkExternalMemoryHandleTypeFlags external_types;
    VkDeviceMemory mem;
};

struct fake_memory {
    int live;
    size_t size;
    uint8_t *host;
    int mapped;
    int imported;
    const void *import_ptr;
};

struct fake_copy {
    VkBuffer src;
    VkBuffer dst;
    VkDeviceSize src_off;
    VkDeviceSize dst_off;
    VkDeviceSize size;
};

static struct fake_buffer g_bufs[FAKE_MAX_BUF];
static struct fake_memory g_mems[FAKE_MAX_MEM];
static int g_dev_token, g_inst_token, g_phys_token, g_queue_token, g_pool_token;
static int g_cmd_token, g_fence_token;

static struct {
    // 故障注入。
    int fail_create_buffer;
    int fail_allocate;
    int fail_bind;
    int fail_map;
    int fail_create_fence;
    VkResult create_buffer_result;
    VkResult allocate_result;
    VkResult bind_result;
    VkResult map_result;
    VkResult create_fence_result;
    // host import 扩展的行为。
    int expose_host_pointer_properties;
    int reject_host_pointer;
    uint32_t host_pointer_type_bits;
    int host_pointer_properties_calls;
    // vkGetBufferMemoryRequirements。
    uint32_t requested_type_bits;
    VkDeviceSize requested_size;   // 0 = 按 buffer size 向上取整到 4 KiB
    // fake GPU。
    int gpu_copy_enabled;
    // 调用计数。
    int create_buffer_n, destroy_buffer_n, allocate_n, free_n, bind_n, map_n, unmap_n;
    int import_allocate_n;   // 带 VkImportMemoryHostPointerInfoEXT 的内存分配次数
    int flush_n, invalidate_n, procfn_n;
    int cmd_allocate_n, cmd_free_n, fence_create_n, fence_destroy_n, submit_n, wait_n;
    int reset_cmd_n, fence_reset_n, device_idle_n, barrier_n, copy_n;
    // 参数观察。
    uint32_t last_memory_type_index;
    int last_allocate_had_import;
    const void *last_allocate_import_ptr;
    VkDeviceMemory last_flush_memory;
    VkDeviceSize last_flush_size;
    int last_flush_count;
    VkDeviceMemory last_invalidate_memory;
    int last_invalidate_count;
    struct fake_copy copies[FAKE_MAX_COPY];
    int copy_pending;
    // 调用顺序。
    int order[64];
    int order_n;
} g;

static struct fake_buffer *buf_of(VkBuffer handle) {
    for (int i = 0; i < FAKE_MAX_BUF; i++)
        if (g_bufs[i].live && (VkBuffer)(void *)&g_bufs[i] == handle) return &g_bufs[i];
    return NULL;
}
static struct fake_memory *mem_of(VkDeviceMemory handle) {
    for (int i = 0; i < FAKE_MAX_MEM; i++)
        if (g_mems[i].live && (VkDeviceMemory)(void *)&g_mems[i] == handle) return &g_mems[i];
    return NULL;
}

static void mark(int ev) {
    if (g.order_n < (int)(sizeof g.order / sizeof g.order[0])) g.order[g.order_n++] = ev;
}
static int order_is(const int *want, int n) {
    if (g.order_n != n) return 0;
    for (int i = 0; i < n; i++)
        if (g.order[i] != want[i]) return 0;
    return 1;
}
static int live_buffers(void) {
    int n = 0;
    for (int i = 0; i < FAKE_MAX_BUF; i++) n += g_bufs[i].live ? 1 : 0;
    return n;
}
static int live_memories(void) {
    int n = 0;
    for (int i = 0; i < FAKE_MAX_MEM; i++) n += g_mems[i].live ? 1 : 0;
    return n;
}

static void fake_reset(void) {
    for (int i = 0; i < FAKE_MAX_MEM; i++)
        if (g_mems[i].live && g_mems[i].host && !g_mems[i].imported) free(g_mems[i].host);
    memset(g_bufs, 0, sizeof g_bufs);
    memset(g_mems, 0, sizeof g_mems);
    memset(&g, 0, sizeof g);
    g.create_buffer_result = VK_SUCCESS;
    g.allocate_result = VK_SUCCESS;
    g.bind_result = VK_SUCCESS;
    g.map_result = VK_SUCCESS;
    g.create_fence_result = VK_SUCCESS;
    g.expose_host_pointer_properties = 1;
    g.requested_type_bits = 0x3;
    g.host_pointer_type_bits = 0x1;
    g.gpu_copy_enabled = 1;
}

// 宿主侧 64 字节对齐的普通内存；测试里模拟 guest 池直映射地址。
static void *host_aligned(size_t n) {
    void *p = NULL;
    if (posix_memalign(&p, 64, n) != 0) return NULL;
    memset(p, 0, n);
    return p;
}

// ---- fake Vulkan 入口 ------------------------------------------------------
VKAPI_ATTR VkResult VKAPI_CALL vkCreateBuffer(VkDevice device, const VkBufferCreateInfo *info,
                                              const VkAllocationCallbacks *allocator, VkBuffer *out) {
    g.create_buffer_n++;
    mark(EV_CREATE_BUFFER);
    if (g.fail_create_buffer) return g.create_buffer_result;
    if (!out) return VK_ERROR_INITIALIZATION_FAILED;
    for (int i = 0; i < FAKE_MAX_BUF; i++) {
        if (g_bufs[i].live) continue;
        memset(&g_bufs[i], 0, sizeof g_bufs[i]);
        g_bufs[i].live = 1;
        g_bufs[i].size = info->size;
        g_bufs[i].usage = info->usage;
        for (const VkBaseInStructure *base = (const VkBaseInStructure *)info->pNext; base; base = base->pNext) {
            if (base->sType == VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_BUFFER_CREATE_INFO) {
                const VkExternalMemoryBufferCreateInfo *ext = (const VkExternalMemoryBufferCreateInfo *)base;
                g_bufs[i].has_external_info = 1;
                g_bufs[i].external_types = ext->handleTypes;
            }
        }
        *out = (VkBuffer)(void *)&g_bufs[i];
        return VK_SUCCESS;
    }
    return VK_ERROR_OUT_OF_DEVICE_MEMORY;
}

VKAPI_ATTR void VKAPI_CALL vkGetBufferMemoryRequirements(VkDevice device, VkBuffer buffer,
                                                         VkMemoryRequirements *req) {
    struct fake_buffer *b = buf_of(buffer);
    memset(req, 0, sizeof *req);
    if (!b) return;
    req->size = g.requested_size ? g.requested_size : ((b->size + 0xfff) & ~(VkDeviceSize)0xfff);
    if (req->size == 0) req->size = 0x1000;
    req->alignment = 0x1000;
    req->memoryTypeBits = g.requested_type_bits;
}

VKAPI_ATTR VkResult VKAPI_CALL vkAllocateMemory(VkDevice device, const VkMemoryAllocateInfo *info,
                                                const VkAllocationCallbacks *allocator,
                                                VkDeviceMemory *out) {
    g.allocate_n++;
    mark(EV_ALLOCATE_MEMORY);
    if (g.fail_allocate) return g.allocate_result;
    if (!out) return VK_ERROR_INITIALIZATION_FAILED;
    int slot = -1;
    for (int i = 0; i < FAKE_MAX_MEM; i++)
        if (!g_mems[i].live) { slot = i; break; }
    if (slot < 0) return VK_ERROR_OUT_OF_DEVICE_MEMORY;
    struct fake_memory *m = &g_mems[slot];
    memset(m, 0, sizeof *m);
    m->size = (size_t)info->allocationSize;
    g.last_memory_type_index = info->memoryTypeIndex;
    g.last_allocate_had_import = 0;
    for (const VkBaseInStructure *base = (const VkBaseInStructure *)info->pNext; base; base = base->pNext) {
        if (base->sType == VK_STRUCTURE_TYPE_IMPORT_MEMORY_HOST_POINTER_INFO_EXT) {
            const VkImportMemoryHostPointerInfoEXT *imp = (const VkImportMemoryHostPointerInfoEXT *)base;
            m->imported = 1;
            m->import_ptr = imp->pHostPointer;
            m->host = (uint8_t *)imp->pHostPointer;
            g.import_allocate_n++;
            g.last_allocate_had_import = 1;
            g.last_allocate_import_ptr = imp->pHostPointer;
        }
    }
    if (!m->imported) {
        m->host = calloc(1, m->size ? m->size : 1);
        if (!m->host) {
            memset(m, 0, sizeof *m);
            return VK_ERROR_OUT_OF_HOST_MEMORY;
        }
    }
    m->live = 1;
    *out = (VkDeviceMemory)(void *)m;
    return VK_SUCCESS;
}

VKAPI_ATTR VkResult VKAPI_CALL vkBindBufferMemory(VkDevice device, VkBuffer buffer,
                                                  VkDeviceMemory memory, VkDeviceSize offset) {
    g.bind_n++;
    mark(EV_BIND_BUFFER_MEMORY);
    if (g.fail_bind) return g.bind_result;
    struct fake_buffer *b = buf_of(buffer);
    struct fake_memory *m = mem_of(memory);
    if (!b || !m || offset != 0) return VK_ERROR_INITIALIZATION_FAILED;
    b->mem = memory;
    return VK_SUCCESS;
}

VKAPI_ATTR VkResult VKAPI_CALL vkMapMemory(VkDevice device, VkDeviceMemory memory, VkDeviceSize offset,
                                           VkDeviceSize size, VkMemoryMapFlags flags, void **data) {
    g.map_n++;
    mark(EV_MAP_MEMORY);
    if (g.fail_map) return g.map_result;
    struct fake_memory *m = mem_of(memory);
    if (!m || !m->host || !data) return VK_ERROR_MEMORY_MAP_FAILED;
    m->mapped++;
    *data = m->host + (size_t)offset;
    return VK_SUCCESS;
}

VKAPI_ATTR void VKAPI_CALL vkUnmapMemory(VkDevice device, VkDeviceMemory memory) {
    g.unmap_n++;
    mark(EV_UNMAP_MEMORY);
    struct fake_memory *m = mem_of(memory);
    if (m && m->mapped > 0) m->mapped--;
}

VKAPI_ATTR void VKAPI_CALL vkDestroyBuffer(VkDevice device, VkBuffer buffer,
                                           const VkAllocationCallbacks *allocator) {
    g.destroy_buffer_n++;
    mark(EV_DESTROY_BUFFER);
    struct fake_buffer *b = buf_of(buffer);
    if (b) memset(b, 0, sizeof *b);
}

VKAPI_ATTR void VKAPI_CALL vkFreeMemory(VkDevice device, VkDeviceMemory memory,
                                        const VkAllocationCallbacks *allocator) {
    g.free_n++;
    mark(EV_FREE_MEMORY);
    struct fake_memory *m = mem_of(memory);
    if (!m) return;
    if (!m->imported) free(m->host);   // 导入的 host 指针所有权不归 Vulkan，不能 free
    memset(m, 0, sizeof *m);
}

VKAPI_ATTR VkResult VKAPI_CALL vkFlushMappedMemoryRanges(VkDevice device, uint32_t count,
                                                         const VkMappedMemoryRange *ranges) {
    g.flush_n++;
    mark(EV_FLUSH);
    g.last_flush_count = (int)count;
    if (count) {
        g.last_flush_memory = ranges[0].memory;
        g.last_flush_size = ranges[0].size;
    }
    return VK_SUCCESS;
}

VKAPI_ATTR VkResult VKAPI_CALL vkInvalidateMappedMemoryRanges(VkDevice device, uint32_t count,
                                                              const VkMappedMemoryRange *ranges) {
    g.invalidate_n++;
    mark(EV_INVALIDATE);
    g.last_invalidate_count = (int)count;
    if (count) g.last_invalidate_memory = ranges[0].memory;
    return VK_SUCCESS;
}

static VKAPI_ATTR VkResult VKAPI_CALL fake_host_pointer_properties(
    VkDevice device, VkExternalMemoryHandleTypeFlagBits handle_type, const void *host,
    VkMemoryHostPointerPropertiesEXT *props) {
    g.host_pointer_properties_calls++;
    if (g.reject_host_pointer) return VK_ERROR_INVALID_EXTERNAL_HANDLE;
    if (props) {
        memset(props, 0, sizeof *props);
        props->sType = VK_STRUCTURE_TYPE_MEMORY_HOST_POINTER_PROPERTIES_EXT;
        props->memoryTypeBits = g.host_pointer_type_bits;
    }
    return VK_SUCCESS;
}

VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL vkGetDeviceProcAddr(VkDevice device, const char *name) {
    g.procfn_n++;
    if (g.expose_host_pointer_properties && name &&
        strcmp(name, "vkGetMemoryHostPointerPropertiesEXT") == 0)
        return (PFN_vkVoidFunction)fake_host_pointer_properties;
    return NULL;
}

VKAPI_ATTR void VKAPI_CALL vkGetPhysicalDeviceExternalBufferProperties(
    VkPhysicalDevice physical, const VkPhysicalDeviceExternalBufferInfo *info,
    VkExternalBufferProperties *props) {
    memset(props, 0, sizeof *props);
    props->externalMemoryProperties.externalMemoryFeatures = VK_EXTERNAL_MEMORY_FEATURE_IMPORTABLE_BIT;
    props->externalMemoryProperties.compatibleHandleTypes = info->handleType;
}

// ---- fake 命令提交：fence 等待时执行“GPU 拷贝” ----------------------------
static void fake_gpu_copy(void) {
    if (g.copy_n <= 0) return;
    const struct fake_copy *c = &g.copies[(g.copy_n - 1) % FAKE_MAX_COPY];
    struct fake_buffer *src_buf = buf_of(c->src);
    struct fake_buffer *dst_buf = buf_of(c->dst);
    if (!src_buf || !dst_buf) return;
    struct fake_memory *src_mem = mem_of(src_buf->mem);
    struct fake_memory *dst_mem = mem_of(dst_buf->mem);
    if (!src_mem || !dst_mem || !src_mem->host || !dst_mem->host) return;
    if (c->src_off + c->size > (VkDeviceSize)src_mem->size) return;
    if (c->dst_off + c->size > (VkDeviceSize)dst_mem->size) return;
    memcpy(dst_mem->host + (size_t)c->dst_off, src_mem->host + (size_t)c->src_off, (size_t)c->size);
}

VKAPI_ATTR VkResult VKAPI_CALL vkAllocateCommandBuffers(VkDevice device,
                                                        const VkCommandBufferAllocateInfo *info,
                                                        VkCommandBuffer *out) {
    g.cmd_allocate_n++;
    if (!out) return VK_ERROR_INITIALIZATION_FAILED;
    *out = (VkCommandBuffer)(void *)&g_cmd_token;
    return VK_SUCCESS;
}

VKAPI_ATTR void VKAPI_CALL vkFreeCommandBuffers(VkDevice device, VkCommandPool pool, uint32_t count,
                                                const VkCommandBuffer *buffers) {
    g.cmd_free_n++;
}

VKAPI_ATTR VkResult VKAPI_CALL vkCreateFence(VkDevice device, const VkFenceCreateInfo *info,
                                             const VkAllocationCallbacks *allocator, VkFence *out) {
    g.fence_create_n++;
    if (g.fail_create_fence) return g.create_fence_result;
    if (!out) return VK_ERROR_INITIALIZATION_FAILED;
    *out = (VkFence)(void *)&g_fence_token;
    return VK_SUCCESS;
}

VKAPI_ATTR void VKAPI_CALL vkDestroyFence(VkDevice device, VkFence fence,
                                          const VkAllocationCallbacks *allocator) {
    g.fence_destroy_n++;
}

VKAPI_ATTR VkResult VKAPI_CALL vkResetFences(VkDevice device, uint32_t count, const VkFence *fences) {
    g.fence_reset_n++;
    return VK_SUCCESS;
}

VKAPI_ATTR VkResult VKAPI_CALL vkBeginCommandBuffer(VkCommandBuffer cmd,
                                                    const VkCommandBufferBeginInfo *info) {
    return VK_SUCCESS;
}

VKAPI_ATTR VkResult VKAPI_CALL vkEndCommandBuffer(VkCommandBuffer cmd) { return VK_SUCCESS; }

VKAPI_ATTR VkResult VKAPI_CALL vkResetCommandBuffer(VkCommandBuffer cmd, VkCommandBufferResetFlags flags) {
    g.reset_cmd_n++;
    return VK_SUCCESS;
}

VKAPI_ATTR void VKAPI_CALL vkCmdPipelineBarrier(VkCommandBuffer cmd, VkPipelineStageFlags src_stage,
                                                VkPipelineStageFlags dst_stage, VkDependencyFlags flags,
                                                uint32_t memory_count, const VkMemoryBarrier *memories,
                                                uint32_t buffer_count, const VkBufferMemoryBarrier *buffers,
                                                uint32_t image_count, const VkImageMemoryBarrier *images) {
    g.barrier_n++;
}

VKAPI_ATTR void VKAPI_CALL vkCmdCopyBuffer(VkCommandBuffer cmd, VkBuffer src, VkBuffer dst,
                                           uint32_t count, const VkBufferCopy *regions) {
    g.copy_n++;
    mark(EV_CMD_COPY);
    if (!count || !regions) return;
    struct fake_copy *c = &g.copies[(g.copy_n - 1) % FAKE_MAX_COPY];
    memset(c, 0, sizeof *c);
    c->src = src;
    c->dst = dst;
    c->src_off = regions[0].srcOffset;
    c->dst_off = regions[0].dstOffset;
    c->size = regions[0].size;
    g.copy_pending = 1;
}

VKAPI_ATTR VkResult VKAPI_CALL vkQueueSubmit(VkQueue queue, uint32_t count,
                                             const VkSubmitInfo *submits, VkFence fence) {
    g.submit_n++;
    mark(EV_SUBMIT);
    return VK_SUCCESS;
}

VKAPI_ATTR VkResult VKAPI_CALL vkWaitForFences(VkDevice device, uint32_t count, const VkFence *fences,
                                               VkBool32 wait_all, uint64_t timeout) {
    g.wait_n++;
    mark(EV_WAIT);
    if (g.copy_pending && g.gpu_copy_enabled) fake_gpu_copy();
    g.copy_pending = 0;
    return VK_SUCCESS;
}

VKAPI_ATTR VkResult VKAPI_CALL vkDeviceWaitIdle(VkDevice device) {
    g.device_idle_n++;
    return VK_SUCCESS;
}

// ---- s2a_vk_memory_type 替身 ----------------------------------------------
// 生产实现在 vk_device.c（宿主单测不链它）。替身语义与生产一致：只在 type_bits 选中的
// memory type 里找第一个满足 required 的；actual 写该 type 的实际 propertyFlags；
// 返回 UINT32_MAX 表示没有满足的类型（调用方据此判“没有 host-visible / 没有共享类型”）。
uint32_t s2a_vk_memory_type(const struct s2a_vk_device *device, uint32_t type_bits,
                            VkMemoryPropertyFlags required, VkMemoryPropertyFlags *actual) {
    if (!device) return UINT32_MAX;
    uint32_t n = device->memory.memoryTypeCount < 32 ? device->memory.memoryTypeCount : 32;
    for (uint32_t i = 0; i < n; i++) {
        VkMemoryPropertyFlags flags = device->memory.memoryTypes[i].propertyFlags;
        if ((type_bits & (1u << i)) && (flags & required) == required) {
            if (actual) *actual = flags;
            return i;
        }
    }
    return UINT32_MAX;
}

// ---- 测试辅助 -------------------------------------------------------------
static void dev_init(struct s2a_vk_device *d) {
    memset(d, 0, sizeof *d);
    d->instance = (VkInstance)(void *)&g_inst_token;
    d->physical = (VkPhysicalDevice)(void *)&g_phys_token;
    d->device = (VkDevice)(void *)&g_dev_token;
    d->queue = (VkQueue)(void *)&g_queue_token;
    d->command_pool = (VkCommandPool)(void *)&g_pool_token;
    d->memory.memoryTypeCount = 2;
    d->memory.memoryTypes[0].propertyFlags =
        VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    d->memory.memoryTypes[1].propertyFlags = VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT;
}

static void mem_types(struct s2a_vk_device *d, uint32_t count, const VkMemoryPropertyFlags *flags) {
    d->memory.memoryTypeCount = count;
    for (uint32_t i = 0; i < count; i++) {
        d->memory.memoryTypes[i].propertyFlags = flags[i];
        d->memory.memoryTypes[i].heapIndex = 0;
    }
}

int main(void) {
    struct s2a_vk_device dev;
    struct s2a_gpu_mem_caps caps;
    struct s2a_gpu_buf b;
    char why[256];

    // 1) 能力探测 -------------------------------------------------------------
    case_begin("caps_get_before_probe");
    CHECK(s2a_gpu_mem_caps_get() == NULL);   // 还没 probe 过：调用方必须能区分“没有 caps”
    case_end();

    case_begin("probe_field_mapping");
    {
        fake_reset();
        dev_init(&dev);
        dev.external_memory_host_enabled = 1;
        dev.host_pointer_alignment = 4096;
        setenv("debug.s2a.mem_shared", "1", 1);
        why[0] = 0;
        memset(&caps, 0xAA, sizeof caps);
        CHECK(s2a_gpu_mem_probe(&dev, &caps, why, sizeof why) == 0);
        CHECK(caps.host_import == 1);
        CHECK(caps.host_align == (VkDeviceSize)4096);
        CHECK(caps.ahb == 0);        // 宿主构建没有 Android 扩展枚举分支
        CHECK(caps.dmabuf == 0);
        CHECK(caps.shared_enabled == 1);
        CHECK(caps.chosen == S2A_GPU_MEM_UPLOAD);
        CHECK(why[0] == 0);
        const struct s2a_gpu_mem_caps *got = s2a_gpu_mem_caps_get();
        CHECK(got != NULL);
        CHECK(got && memcmp(got, &caps, sizeof caps) == 0);
        // 再探一次：字段跟着设备属性实时变化，不是缓存第一次的旧值。
        dev.external_memory_host_enabled = 0;
        dev.host_pointer_alignment = 64;
        unsetenv("debug.s2a.mem_shared");
        why[0] = 0;
        CHECK(s2a_gpu_mem_probe(&dev, &caps, why, sizeof why) == 0);
        CHECK(caps.host_import == 0);
        CHECK(caps.host_align == (VkDeviceSize)64);
        CHECK(caps.shared_enabled == 0);
    }
    case_end();

    case_begin("probe_reject_no_device");
    {
        fake_reset();
        dev_init(&dev);
        why[0] = 0;
        CHECK(s2a_gpu_mem_probe(NULL, &caps, why, sizeof why) != 0);
        CHECK(strstr(why, "no device") != NULL);
        dev.device = VK_NULL_HANDLE;
        why[0] = 0;
        CHECK(s2a_gpu_mem_probe(&dev, &caps, why, sizeof why) != 0);
        CHECK(strstr(why, "no device") != NULL);
    }
    case_end();

    case_begin("probe_reject_no_caps");
    {
        fake_reset();
        dev_init(&dev);
        const struct s2a_gpu_mem_caps *before = s2a_gpu_mem_caps_get();
        struct s2a_gpu_mem_caps snapshot;
        CHECK(before != NULL);
        if (before) snapshot = *before; else memset(&snapshot, 0, sizeof snapshot);
        why[0] = 0;
        CHECK(s2a_gpu_mem_probe(&dev, NULL, why, sizeof why) != 0);
        CHECK(strstr(why, "no caps") != NULL);
        // 拒绝时不能污染上一次成功的 g_caps（否则调用方会拿到半张表）。
        CHECK(s2a_gpu_mem_caps_get() == before);
        CHECK(before == NULL || memcmp(before, &snapshot, sizeof snapshot) == 0);
    }
    case_end();

    // 2) UPLOAD 分配 ----------------------------------------------------------
    case_begin("upload_coherent_preferred");
    {
        fake_reset();
        dev_init(&dev);
        const VkMemoryPropertyFlags flags[3] = {
            VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT,
            VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        };
        mem_types(&dev, 3, flags);
        g.requested_type_bits = 0x7;
        memset(&b, 0xAA, sizeof b);
        why[0] = 0;
        CHECK(s2a_gpu_buf_create(&dev, (VkDeviceSize)0x1000, VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                                 S2A_GPU_MEM_UPLOAD, &b, why, sizeof why) == 0);
        CHECK(b.kind == S2A_GPU_MEM_UPLOAD);
        CHECK(b.buf != VK_NULL_HANDLE);
        CHECK(b.mem != VK_NULL_HANDLE);
        CHECK(b.size == (VkDeviceSize)0x1000);
        CHECK(b.alloc_size == (VkDeviceSize)0x1000);
        CHECK(b.mapped == 1);
        CHECK(b.cpu != NULL);
        CHECK(b.coherent == 1);
        // 优先挑 HOST_COHERENT（type 1），不是第一个 host-visible（type 0）。
        CHECK(g.last_memory_type_index == 1);
        CHECK(g.create_buffer_n == 1 && g.allocate_n == 1 && g.bind_n == 1 && g.map_n == 1);
        struct fake_buffer *fb = buf_of(b.buf);
        CHECK(fb != NULL && fb->has_external_info == 0);   // 上传路径不声明 external handleTypes
        s2a_gpu_buf_flush(&dev, &b, 0, b.size);
        s2a_gpu_buf_invalidate(&dev, &b, 0, b.size);
        CHECK(g.flush_n == 0);        // HOST_COHERENT：flush/invalidate 不真调用
        CHECK(g.invalidate_n == 0);
        s2a_gpu_buf_destroy(&dev, &b);
        CHECK(live_buffers() == 0 && live_memories() == 0);
    }
    case_end();

    case_begin("upload_noncoherent_flushes");
    {
        fake_reset();
        dev_init(&dev);
        const VkMemoryPropertyFlags flags[2] = {
            VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT,
            VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        };
        mem_types(&dev, 2, flags);
        g.requested_type_bits = 0x3;
        why[0] = 0;
        CHECK(s2a_gpu_buf_create(&dev, (VkDeviceSize)0x2000, VK_BUFFER_USAGE_TRANSFER_DST_BIT,
                                 S2A_GPU_MEM_UPLOAD, &b, why, sizeof why) == 0);
        CHECK(b.coherent == 0);
        CHECK(b.mapped == 1);
        CHECK(b.cpu != NULL);
        CHECK(g.last_memory_type_index == 0);
        // 非一致内存：flush/invalidate 必须真的调用，且传的是整块内存。
        s2a_gpu_buf_flush(&dev, &b, 0x40, 0x80);
        CHECK(g.flush_n == 1);
        CHECK(g.last_flush_count == 1);
        CHECK(g.last_flush_memory == b.mem);
        CHECK(g.last_flush_size == VK_WHOLE_SIZE);
        s2a_gpu_buf_invalidate(&dev, &b, 0x40, 0x80);
        CHECK(g.invalidate_n == 1);
        CHECK(g.last_invalidate_count == 1);
        CHECK(g.last_invalidate_memory == b.mem);
        // 空句柄 / 空 device / 未绑定内存不产生调用（不能对 VK_NULL_HANDLE 发 cache 维护）。
        s2a_gpu_buf_flush(NULL, &b, 0, 0);
        s2a_gpu_buf_invalidate(NULL, &b, 0, 0);
        s2a_gpu_buf_flush(&dev, NULL, 0, 0);
        s2a_gpu_buf_invalidate(&dev, NULL, 0, 0);
        struct s2a_gpu_buf empty;
        memset(&empty, 0, sizeof empty);
        s2a_gpu_buf_flush(&dev, &empty, 0, 0);
        s2a_gpu_buf_invalidate(&dev, &empty, 0, 0);
        CHECK(g.flush_n == 1 && g.invalidate_n == 1);
        s2a_gpu_buf_destroy(&dev, &b);
        CHECK(live_buffers() == 0 && live_memories() == 0);
    }
    case_end();

    case_begin("upload_kind_none_selects_upload");
    {
        fake_reset();
        dev_init(&dev);
        // 宿主 caps.chosen 恒 UPLOAD；shared_enabled=1 时 NONE 仍必须落到 UPLOAD（不是 NONE/AHB）。
        setenv("debug.s2a.mem_shared", "1", 1);
        why[0] = 0;
        CHECK(s2a_gpu_mem_probe(&dev, &caps, why, sizeof why) == 0);
        CHECK(caps.shared_enabled == 1 && caps.chosen == S2A_GPU_MEM_UPLOAD);
        why[0] = 0;
        CHECK(s2a_gpu_buf_create(&dev, (VkDeviceSize)0x1000, VK_BUFFER_USAGE_TRANSFER_DST_BIT,
                                 S2A_GPU_MEM_NONE, &b, why, sizeof why) == 0);
        CHECK(b.kind == S2A_GPU_MEM_UPLOAD);
        s2a_gpu_buf_destroy(&dev, &b);
        unsetenv("debug.s2a.mem_shared");
        // 没有共享要求时同样落到 UPLOAD。
        why[0] = 0;
        CHECK(s2a_gpu_mem_probe(&dev, &caps, why, sizeof why) == 0);
        CHECK(caps.shared_enabled == 0 && caps.chosen == S2A_GPU_MEM_UPLOAD);
        why[0] = 0;
        CHECK(s2a_gpu_buf_create(&dev, (VkDeviceSize)0x1000, VK_BUFFER_USAGE_TRANSFER_DST_BIT,
                                 S2A_GPU_MEM_NONE, &b, why, sizeof why) == 0);
        CHECK(b.kind == S2A_GPU_MEM_UPLOAD);
        s2a_gpu_buf_destroy(&dev, &b);
        CHECK(live_buffers() == 0 && live_memories() == 0);
    }
    case_end();

    case_begin("upload_reject_host_import_kind");
    {
        fake_reset();
        dev_init(&dev);
        memset(&b, 0xAA, sizeof b);
        why[0] = 0;
        CHECK(s2a_gpu_buf_create(&dev, (VkDeviceSize)0x1000, VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                                 S2A_GPU_MEM_HOST_IMPORT, &b, why, sizeof why) != 0);
        CHECK(strstr(why, "needs an existing pointer") != NULL);
        CHECK(b.buf == VK_NULL_HANDLE);
        CHECK(b.mem == VK_NULL_HANDLE);
        CHECK(b.kind == 0);
        CHECK(g.create_buffer_n == 0 && g.allocate_n == 0);
    }
    case_end();

    case_begin("create_bad_arguments");
    {
        fake_reset();
        dev_init(&dev);
        why[0] = 0;
        CHECK(s2a_gpu_buf_create(NULL, (VkDeviceSize)0x1000, VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                                 S2A_GPU_MEM_UPLOAD, &b, why, sizeof why) != 0);
        CHECK(strstr(why, "bad arguments") != NULL);
        why[0] = 0;
        CHECK(s2a_gpu_buf_create(&dev, (VkDeviceSize)0x1000, VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                                 S2A_GPU_MEM_UPLOAD, NULL, why, sizeof why) != 0);
        CHECK(strstr(why, "bad arguments") != NULL);
        dev.device = VK_NULL_HANDLE;
        why[0] = 0;
        CHECK(s2a_gpu_buf_create(&dev, (VkDeviceSize)0x1000, VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                                 S2A_GPU_MEM_UPLOAD, &b, why, sizeof why) != 0);
        CHECK(strstr(why, "bad arguments") != NULL);
        CHECK(g.create_buffer_n == 0);
    }
    case_end();

    // 3) 错误路径：不留半分配 ------------------------------------------------
    case_begin("upload_no_host_visible_type");
    {
        fake_reset();
        dev_init(&dev);
        const VkMemoryPropertyFlags flags[1] = { VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT };
        mem_types(&dev, 1, flags);
        g.requested_type_bits = 0x1;
        memset(&b, 0xAA, sizeof b);
        why[0] = 0;
        CHECK(s2a_gpu_buf_create(&dev, (VkDeviceSize)0x1000, VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                                 S2A_GPU_MEM_UPLOAD, &b, why, sizeof why) != 0);
        CHECK(strstr(why, "no host-visible memory type") != NULL);
        CHECK(b.buf == VK_NULL_HANDLE && b.mem == VK_NULL_HANDLE);
        CHECK(g.create_buffer_n == 1 && g.destroy_buffer_n == 1);
        CHECK(g.allocate_n == 0 && g.free_n == 0);
        CHECK(live_buffers() == 0);
    }
    case_end();

    case_begin("upload_create_buffer_fails");
    {
        fake_reset();
        dev_init(&dev);
        g.fail_create_buffer = 1;
        g.create_buffer_result = VK_ERROR_OUT_OF_DEVICE_MEMORY;
        memset(&b, 0xAA, sizeof b);
        why[0] = 0;
        CHECK(s2a_gpu_buf_create(&dev, (VkDeviceSize)0x1000, VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                                 S2A_GPU_MEM_UPLOAD, &b, why, sizeof why) != 0);
        CHECK(strstr(why, "vkCreateBuffer failed") != NULL);
        CHECK(b.buf == VK_NULL_HANDLE && b.mem == VK_NULL_HANDLE);
        CHECK(g.destroy_buffer_n == 0 && g.allocate_n == 0 && g.free_n == 0);
        CHECK(live_buffers() == 0 && live_memories() == 0);
    }
    case_end();

    case_begin("upload_allocate_fails");
    {
        fake_reset();
        dev_init(&dev);
        g.fail_allocate = 1;
        g.allocate_result = VK_ERROR_OUT_OF_DEVICE_MEMORY;
        memset(&b, 0xAA, sizeof b);
        why[0] = 0;
        CHECK(s2a_gpu_buf_create(&dev, (VkDeviceSize)0x1000, VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                                 S2A_GPU_MEM_UPLOAD, &b, why, sizeof why) != 0);
        CHECK(strstr(why, "vkAllocateMemory failed") != NULL);
        CHECK(b.buf == VK_NULL_HANDLE && b.mem == VK_NULL_HANDLE);
        CHECK(g.create_buffer_n == 1 && g.destroy_buffer_n == 1);
        CHECK(g.allocate_n == 1 && g.free_n == 0);
        CHECK(live_buffers() == 0 && live_memories() == 0);
    }
    case_end();

    case_begin("upload_bind_fails");
    {
        fake_reset();
        dev_init(&dev);
        g.fail_bind = 1;
        g.bind_result = VK_ERROR_OUT_OF_DEVICE_MEMORY;
        memset(&b, 0xAA, sizeof b);
        why[0] = 0;
        CHECK(s2a_gpu_buf_create(&dev, (VkDeviceSize)0x1000, VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                                 S2A_GPU_MEM_UPLOAD, &b, why, sizeof why) != 0);
        CHECK(strstr(why, "vkBindBufferMemory failed") != NULL);
        CHECK(b.buf == VK_NULL_HANDLE && b.mem == VK_NULL_HANDLE);
        CHECK(g.free_n == 1 && g.destroy_buffer_n == 1);
        const int want[] = { EV_CREATE_BUFFER, EV_ALLOCATE_MEMORY, EV_BIND_BUFFER_MEMORY,
                             EV_FREE_MEMORY, EV_DESTROY_BUFFER };
        CHECK(order_is(want, 5));   // 先 free 内存，再 destroy buffer
        CHECK(live_buffers() == 0 && live_memories() == 0);
    }
    case_end();

    case_begin("upload_map_fails");
    {
        fake_reset();
        dev_init(&dev);
        g.fail_map = 1;
        g.map_result = VK_ERROR_MEMORY_MAP_FAILED;
        why[0] = 0;
        // 映射失败不算分配失败：缓冲可用、只是 CPU 侧不可写（mapped=0）。
        CHECK(s2a_gpu_buf_create(&dev, (VkDeviceSize)0x1000, VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                                 S2A_GPU_MEM_UPLOAD, &b, why, sizeof why) == 0);
        CHECK(b.kind == S2A_GPU_MEM_UPLOAD);
        CHECK(b.mapped == 0 && b.cpu == NULL);
        CHECK(g.map_n == 1);
        s2a_gpu_buf_destroy(&dev, &b);
        const int want[] = { EV_CREATE_BUFFER, EV_ALLOCATE_MEMORY, EV_BIND_BUFFER_MEMORY,
                             EV_MAP_MEMORY, EV_DESTROY_BUFFER, EV_FREE_MEMORY };
        CHECK(order_is(want, 6));   // 没映射过就不能 unmap
        CHECK(g.unmap_n == 0);
        CHECK(b.buf == VK_NULL_HANDLE && b.mem == VK_NULL_HANDLE);
        CHECK(live_buffers() == 0 && live_memories() == 0);
    }
    case_end();

    // 4) destroy 顺序与清零 ---------------------------------------------------
    case_begin("destroy_upload_order_and_zero");
    {
        fake_reset();
        dev_init(&dev);
        why[0] = 0;
        CHECK(s2a_gpu_buf_create(&dev, (VkDeviceSize)0x1000, VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                                 S2A_GPU_MEM_UPLOAD, &b, why, sizeof why) == 0);
        CHECK(b.mapped == 1 && b.cpu != NULL);
        s2a_gpu_buf_destroy(&dev, &b);
        const int want[] = { EV_CREATE_BUFFER, EV_ALLOCATE_MEMORY, EV_BIND_BUFFER_MEMORY,
                             EV_MAP_MEMORY, EV_UNMAP_MEMORY, EV_DESTROY_BUFFER, EV_FREE_MEMORY };
        CHECK(order_is(want, 7));
        CHECK(g.unmap_n == 1 && g.destroy_buffer_n == 1 && g.free_n == 1);
        CHECK(b.buf == VK_NULL_HANDLE);
        CHECK(b.mem == VK_NULL_HANDLE);
        CHECK(b.size == 0 && b.alloc_size == 0 && b.kind == 0 && b.coherent == 0 && b.mapped == 0);
        CHECK(b.cpu == NULL && b.ahb == NULL && b.fd == 0);
        CHECK(live_buffers() == 0 && live_memories() == 0);
        // 重复 destroy 必须幂等：不能再 unmap/destroy/free 一次。
        s2a_gpu_buf_destroy(&dev, &b);
        CHECK(g.unmap_n == 1 && g.destroy_buffer_n == 1 && g.free_n == 1);
    }
    case_end();

    // 5) host import ----------------------------------------------------------
    case_begin("import_not_enabled");
    {
        fake_reset();
        dev_init(&dev);
        void *host = host_aligned(0x1000);
        CHECK(host != NULL);
        memset(&b, 0xAA, sizeof b);
        why[0] = 0;
        CHECK(s2a_gpu_buf_import(&dev, host, (VkDeviceSize)0x1000, VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                                 &b, why, sizeof why) != 0);
        CHECK(strstr(why, "not enabled") != NULL);
        CHECK(b.buf == VK_NULL_HANDLE && b.mem == VK_NULL_HANDLE);
        CHECK(g.procfn_n == 0 && g.create_buffer_n == 0 && g.allocate_n == 0);
        free(host);
    }
    case_end();

    case_begin("import_procaddr_missing");
    {
        fake_reset();
        dev_init(&dev);
        dev.external_memory_host_enabled = 1;
        dev.host_pointer_alignment = 64;
        g.expose_host_pointer_properties = 0;   // 扩展 advertise，但 proc addr 拿不到
        void *host = host_aligned(0x1000);
        CHECK(host != NULL);
        memset(&b, 0xAA, sizeof b);
        why[0] = 0;
        CHECK(s2a_gpu_buf_import(&dev, host, (VkDeviceSize)0x1000, VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                                 &b, why, sizeof why) != 0);
        CHECK(strstr(why, "missing") != NULL);
        CHECK(g.procfn_n == 1);
        CHECK(g.create_buffer_n == 0 && g.allocate_n == 0);
        CHECK(b.buf == VK_NULL_HANDLE && b.mem == VK_NULL_HANDLE);
        free(host);
    }
    case_end();

    case_begin("import_pointer_unaligned");
    {
        fake_reset();
        dev_init(&dev);
        dev.external_memory_host_enabled = 1;
        dev.host_pointer_alignment = 64;
        char *raw = malloc(0x2000);
        CHECK(raw != NULL);
        void *host = raw ? (void *)(raw + 1) : NULL;   // 故意错开 1 字节
        memset(&b, 0xAA, sizeof b);
        why[0] = 0;
        CHECK(s2a_gpu_buf_import(&dev, host, (VkDeviceSize)0x1000, VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                                 &b, why, sizeof why) != 0);
        CHECK(strstr(why, "not aligned") != NULL);
        CHECK(g.procfn_n == 1 && g.host_pointer_properties_calls == 1);
        CHECK(g.create_buffer_n == 0 && g.allocate_n == 0);
        free(raw);
    }
    case_end();

    case_begin("import_align_zero_means_one");
    {
        fake_reset();
        dev_init(&dev);
        dev.external_memory_host_enabled = 1;
        dev.host_pointer_alignment = 0;   // 驱动没报对齐：生产按 1 处理
        char *raw = malloc(0x2000);
        CHECK(raw != NULL);
        void *host = raw ? (void *)(raw + 1) : NULL;
        why[0] = 0;
        CHECK(s2a_gpu_buf_import(&dev, host, (VkDeviceSize)0x1000, VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                                 &b, why, sizeof why) == 0);
        CHECK(b.kind == S2A_GPU_MEM_HOST_IMPORT);
        CHECK(b.cpu == host);
        s2a_gpu_buf_destroy(&dev, &b);
        CHECK(live_buffers() == 0 && live_memories() == 0);
        free(raw);
    }
    case_end();

    case_begin("import_driver_rejects");
    {
        fake_reset();
        dev_init(&dev);
        dev.external_memory_host_enabled = 1;
        dev.host_pointer_alignment = 64;
        g.reject_host_pointer = 1;   // 驱动不认这个 host 指针
        void *host = host_aligned(0x1000);
        CHECK(host != NULL);
        memset(&b, 0xAA, sizeof b);
        why[0] = 0;
        CHECK(s2a_gpu_buf_import(&dev, host, (VkDeviceSize)0x1000, VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                                 &b, why, sizeof why) != 0);
        CHECK(strstr(why, "rejected") != NULL);
        CHECK(g.create_buffer_n == 0 && g.allocate_n == 0);
        free(host);
    }
    case_end();

    case_begin("import_no_shared_memory_type");
    {
        fake_reset();
        dev_init(&dev);
        dev.external_memory_host_enabled = 1;
        dev.host_pointer_alignment = 64;
        g.requested_type_bits = 0x1;
        g.host_pointer_type_bits = 0x2;   // buffer 可用 type 与 host 指针可用 type 没有交集
        void *host = host_aligned(0x1000);
        CHECK(host != NULL);
        memset(&b, 0xAA, sizeof b);
        why[0] = 0;
        CHECK(s2a_gpu_buf_import(&dev, host, (VkDeviceSize)0x1000, VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                                 &b, why, sizeof why) != 0);
        CHECK(strstr(why, "no shared memory type") != NULL);
        CHECK(g.create_buffer_n == 1 && g.destroy_buffer_n == 1 && g.allocate_n == 0);
        CHECK(b.buf == VK_NULL_HANDLE && b.mem == VK_NULL_HANDLE);
        CHECK(live_buffers() == 0 && live_memories() == 0);
        free(host);
    }
    case_end();

    case_begin("import_success");
    {
        fake_reset();
        dev_init(&dev);
        dev.external_memory_host_enabled = 1;
        dev.host_pointer_alignment = 64;
        g.requested_type_bits = 0x1;
        g.host_pointer_type_bits = 0x1;
        // 正常情况 requirements 的 size 与 buffer 请求一致；生产新增检查要求 mr.size <= 导入区间。
        void *host = host_aligned(0x1000);
        CHECK(host != NULL);
        memset(&b, 0xAA, sizeof b);
        why[0] = 0;
        CHECK(s2a_gpu_buf_import(&dev, host, (VkDeviceSize)0x1000, VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                                 &b, why, sizeof why) == 0);
        CHECK(b.kind == S2A_GPU_MEM_HOST_IMPORT);
        CHECK(b.buf != VK_NULL_HANDLE && b.mem != VK_NULL_HANDLE);
        CHECK(b.size == (VkDeviceSize)0x1000);
        CHECK(b.alloc_size == (VkDeviceSize)0x1000);
        CHECK(b.cpu == host);      // 导入后 CPU 侧就是原指针，零拷贝
        CHECK(b.mapped == 1);
        CHECK(b.coherent == 1);
        CHECK(g.create_buffer_n == 1 && g.allocate_n == 1 && g.bind_n == 1);
        CHECK(g.map_n == 0);       // 导入路径不调 vkMapMemory
        CHECK(g.last_allocate_had_import == 1);
        CHECK(g.last_allocate_import_ptr == host);
        CHECK(g.last_memory_type_index == 0);
        struct fake_buffer *fb = buf_of(b.buf);
        CHECK(fb != NULL && fb->has_external_info == 1);
        CHECK(fb != NULL && fb->external_types == VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT);
        s2a_gpu_buf_flush(&dev, &b, 0, b.size);
        s2a_gpu_buf_invalidate(&dev, &b, 0, b.size);
        CHECK(g.flush_n == 0 && g.invalidate_n == 0);   // 一致内存照旧免维护
        s2a_gpu_buf_destroy(&dev, &b);
        const int want[] = { EV_CREATE_BUFFER, EV_ALLOCATE_MEMORY, EV_BIND_BUFFER_MEMORY,
                             EV_DESTROY_BUFFER, EV_FREE_MEMORY };
        CHECK(order_is(want, 5));   // 导入缓冲没有 unmap
        CHECK(g.unmap_n == 0);
        CHECK(b.buf == VK_NULL_HANDLE && b.mem == VK_NULL_HANDLE && b.cpu == NULL);
        CHECK(live_buffers() == 0 && live_memories() == 0);
        free(host);
    }
    case_end();

    case_begin("import_noncoherent_flushes");
    {
        fake_reset();
        dev_init(&dev);
        const VkMemoryPropertyFlags flags[2] = {
            VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT,
            VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        };
        mem_types(&dev, 2, flags);
        dev.external_memory_host_enabled = 1;
        dev.host_pointer_alignment = 64;
        g.requested_type_bits = 0x1;
        g.host_pointer_type_bits = 0x1;
        void *host = host_aligned(0x1000);
        CHECK(host != NULL);
        why[0] = 0;
        CHECK(s2a_gpu_buf_import(&dev, host, (VkDeviceSize)0x1000, VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                                 &b, why, sizeof why) == 0);
        CHECK(b.kind == S2A_GPU_MEM_HOST_IMPORT);
        CHECK(b.coherent == 0);    // 导入内存是否一致由驱动属性决定，不按后端名假设
        s2a_gpu_buf_flush(&dev, &b, 0, b.size);
        CHECK(g.flush_n == 1 && g.last_flush_memory == b.mem);
        s2a_gpu_buf_invalidate(&dev, &b, 0, b.size);
        CHECK(g.invalidate_n == 1 && g.last_invalidate_memory == b.mem);
        s2a_gpu_buf_destroy(&dev, &b);
        CHECK(live_buffers() == 0 && live_memories() == 0);
        free(host);
    }
    case_end();

    case_begin("import_allocate_fails");
    {
        fake_reset();
        dev_init(&dev);
        dev.external_memory_host_enabled = 1;
        dev.host_pointer_alignment = 64;
        g.fail_allocate = 1;
        g.allocate_result = VK_ERROR_OUT_OF_DEVICE_MEMORY;
        void *host = host_aligned(0x1000);
        CHECK(host != NULL);
        memset(&b, 0xAA, sizeof b);
        why[0] = 0;
        CHECK(s2a_gpu_buf_import(&dev, host, (VkDeviceSize)0x1000, VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                                 &b, why, sizeof why) != 0);
        CHECK(strstr(why, "vkAllocateMemory(import) failed") != NULL);
        CHECK(b.buf == VK_NULL_HANDLE && b.mem == VK_NULL_HANDLE);
        CHECK(g.create_buffer_n == 1 && g.destroy_buffer_n == 1);
        CHECK(g.allocate_n == 1 && g.free_n == 0);
        CHECK(live_buffers() == 0 && live_memories() == 0);
        free(host);
    }
    case_end();

    case_begin("import_bind_fails");
    {
        fake_reset();
        dev_init(&dev);
        dev.external_memory_host_enabled = 1;
        dev.host_pointer_alignment = 64;
        g.fail_bind = 1;
        g.bind_result = VK_ERROR_OUT_OF_DEVICE_MEMORY;
        void *host = host_aligned(0x1000);
        CHECK(host != NULL);
        memset(&b, 0xAA, sizeof b);
        why[0] = 0;
        CHECK(s2a_gpu_buf_import(&dev, host, (VkDeviceSize)0x1000, VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                                 &b, why, sizeof why) != 0);
        CHECK(strstr(why, "vkBindBufferMemory failed") != NULL);
        CHECK(b.buf == VK_NULL_HANDLE && b.mem == VK_NULL_HANDLE);
        CHECK(g.free_n == 1 && g.destroy_buffer_n == 1);
        const int want[] = { EV_CREATE_BUFFER, EV_ALLOCATE_MEMORY, EV_BIND_BUFFER_MEMORY,
                             EV_FREE_MEMORY, EV_DESTROY_BUFFER };
        CHECK(order_is(want, 5));
        CHECK(live_buffers() == 0 && live_memories() == 0);
        free(host);
    }
    case_end();

    case_begin("import_null_or_zero_rejected");
    {
        fake_reset();
        dev_init(&dev);
        dev.external_memory_host_enabled = 1;
        dev.host_pointer_alignment = 64;
        void *host = host_aligned(0x1000);
        CHECK(host != NULL);
        // host==NULL：必须在碰任何 Vulkan 入口之前拒绝（否则拿 NULL 去查 host 指针属性）。
        why[0] = 0;
        CHECK(s2a_gpu_buf_import(&dev, NULL, (VkDeviceSize)0x1000, VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                                 &b, why, sizeof why) != 0);
        CHECK(strstr(why, "no pointer/size") != NULL);
        CHECK(g.procfn_n == 0 && g.create_buffer_n == 0 && g.allocate_n == 0);
        // size==0：同样拒绝；0 长度的 buffer 分配本身违反 Vulkan 的 size > 0 要求。
        why[0] = 0;
        CHECK(s2a_gpu_buf_import(&dev, host, 0, VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                                 &b, why, sizeof why) != 0);
        CHECK(strstr(why, "no pointer/size") != NULL);
        CHECK(g.procfn_n == 0 && g.create_buffer_n == 0 && g.allocate_n == 0);
        CHECK(live_buffers() == 0 && live_memories() == 0);
        free(host);
    }
    case_end();

    case_begin("import_requirements_exceed_range");
    {
        fake_reset();
        dev_init(&dev);
        dev.external_memory_host_enabled = 1;
        dev.host_pointer_alignment = 64;
        g.requested_type_bits = 0x1;
        g.host_pointer_type_bits = 0x1;
        g.requested_size = 0x4000;   // 驱动要 16 KiB 分配，但导入区间只有 4 KiB
        void *host = host_aligned(0x1000);
        CHECK(host != NULL);
        memset(&b, 0xAA, sizeof b);
        why[0] = 0;
        CHECK(s2a_gpu_buf_import(&dev, host, (VkDeviceSize)0x1000, VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                                 &b, why, sizeof why) != 0);
        CHECK(strstr(why, "requirements exceed the imported range") != NULL);
        // 拒绝发生在建 buffer 之后、分配内存之前：已建的 buffer 必须销毁，不能留半分配。
        CHECK(g.create_buffer_n == 1 && g.destroy_buffer_n == 1);
        CHECK(g.allocate_n == 0 && g.free_n == 0);
        CHECK(b.buf == VK_NULL_HANDLE && b.mem == VK_NULL_HANDLE);
        CHECK(live_buffers() == 0 && live_memories() == 0);
        free(host);
    }
    case_end();

    // 6) 宿主上的 AHB 行为（记录实际语义，不是替它兜底） ---------------------
    case_begin("ahb_unavailable_on_host");
    {
        fake_reset();
        dev_init(&dev);
        why[0] = 0;
        CHECK(s2a_gpu_buf_create(&dev, (VkDeviceSize)0x1000, VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                                 S2A_GPU_MEM_AHB, &b, why, sizeof why) == 0);
        // 宿主 build 没有 AHB 分支：退化成 UPLOAD，kind 也如实写成 UPLOAD（不冒充 AHB）。
        CHECK(b.kind == S2A_GPU_MEM_UPLOAD);
        CHECK(b.buf != VK_NULL_HANDLE && b.mem != VK_NULL_HANDLE);
        CHECK(b.mapped == 1);
        s2a_gpu_buf_destroy(&dev, &b);
        CHECK(live_buffers() == 0 && live_memories() == 0);
    }
    case_end();

    // 7) selftest：CPU 写 → GPU 读 -------------------------------------------
    case_begin("selftest_upload_ok");
    {
        fake_reset();
        dev_init(&dev);
        why[0] = 0;
        CHECK(s2a_gpu_mem_selftest(&dev, S2A_GPU_MEM_UPLOAD, why, sizeof why) == 0);
        CHECK(strncmp(why, "ok kind=1", 9) == 0);
        CHECK(g.copy_n == 2);
        // 两趟方向相反：第一趟 src→dst，第二趟 dst→src；src/dst 是两块独立分配。
        CHECK(g.copies[0].src != g.copies[0].dst);
        CHECK(g.copies[1].src == g.copies[0].dst);
        CHECK(g.copies[1].dst == g.copies[0].src);
        CHECK(g.copies[0].size == (VkDeviceSize)(64 * 1024));
        CHECK(g.copies[0].src_off == 0 && g.copies[0].dst_off == 0);
        CHECK(g.submit_n == 2 && g.wait_n == 2);
        CHECK(g.cmd_allocate_n == 1 && g.cmd_free_n == 1);
        CHECK(g.fence_create_n == 1 && g.fence_destroy_n == 1);
        CHECK(g.reset_cmd_n == 1 && g.fence_reset_n == 1);
        CHECK(g.barrier_n == 1);
        CHECK(g.device_idle_n == 1);
        CHECK(g.flush_n == 0 && g.invalidate_n == 0);   // 一致内存：自检也不发 cache 维护
        CHECK(live_buffers() == 0 && live_memories() == 0);
    }
    case_end();

    case_begin("selftest_noncoherent_flushes");
    {
        fake_reset();
        dev_init(&dev);
        const VkMemoryPropertyFlags flags[2] = {
            VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT,
            VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        };
        mem_types(&dev, 2, flags);
        why[0] = 0;
        CHECK(s2a_gpu_mem_selftest(&dev, S2A_GPU_MEM_UPLOAD, why, sizeof why) == 0);
        // 两趟各 flush 源、invalidate 目标。
        CHECK(g.flush_n == 2);
        CHECK(g.invalidate_n == 2);
        CHECK(live_buffers() == 0 && live_memories() == 0);
    }
    case_end();

    case_begin("selftest_detects_broken_copy");
    {
        fake_reset();
        dev_init(&dev);
        // 负对照：GPU 没真的把 CPU 写进 src 的字节搬到 dst，自检必须红，证明它不是恒绿。
        g.gpu_copy_enabled = 0;
        why[0] = 0;
        CHECK(s2a_gpu_mem_selftest(&dev, S2A_GPU_MEM_UPLOAD, why, sizeof why) != 0);
        CHECK(strstr(why, "GPU read mismatch") != NULL);
        CHECK(g.wait_n == 1);      // 第一趟对读就失败，不再做第二趟
        CHECK(g.copy_n == 1);
        CHECK(live_buffers() == 0 && live_memories() == 0);   // 失败路径也要全部释放
    }
    case_end();

    case_begin("selftest_no_device");
    {
        fake_reset();
        dev_init(&dev);
        why[0] = 0;
        CHECK(s2a_gpu_mem_selftest(NULL, S2A_GPU_MEM_UPLOAD, why, sizeof why) != 0);
        CHECK(strstr(why, "no device") != NULL);
        dev.device = VK_NULL_HANDLE;
        why[0] = 0;
        CHECK(s2a_gpu_mem_selftest(&dev, S2A_GPU_MEM_UPLOAD, why, sizeof why) != 0);
        CHECK(strstr(why, "no device") != NULL);
        CHECK(g.submit_n == 0);
    }
    case_end();

    case_begin("selftest_host_import_ok");
    {
        fake_reset();
        dev_init(&dev);
        dev.external_memory_host_enabled = 1;
        dev.host_pointer_alignment = 64;
        why[0] = 0;
        CHECK(s2a_gpu_mem_selftest(&dev, S2A_GPU_MEM_HOST_IMPORT, why, sizeof why) == 0);
        CHECK(strncmp(why, "ok kind=2", 9) == 0);   // kind=HOST_IMPORT
        // src 是 selftest 自己 posix_memalign + import 的，dst 仍是普通上传缓冲。
        CHECK(g.import_allocate_n == 1);
        CHECK(g.create_buffer_n == 2 && g.allocate_n == 2);
        CHECK(g.map_n == 1);       // 只有 dst 走 vkMapMemory；导入的 src 不映射
        CHECK(g.unmap_n == 1);     // 只有 dst 需要 unmap
        CHECK(g.copy_n == 2);
        CHECK(g.copies[0].src != g.copies[0].dst);
        CHECK(g.copies[1].src == g.copies[0].dst);
        CHECK(g.copies[1].dst == g.copies[0].src);
        CHECK(g.copies[0].size == (VkDeviceSize)(64 * 1024));
        CHECK(g.submit_n == 2 && g.wait_n == 2);
        CHECK(g.flush_n == 0 && g.invalidate_n == 0);   // 一致内存：导入自检也不发 cache 维护
        CHECK(live_buffers() == 0 && live_memories() == 0);
    }
    case_end();

    case_begin("selftest_host_import_default_align");
    {
        fake_reset();
        dev_init(&dev);
        dev.external_memory_host_enabled = 1;
        dev.host_pointer_alignment = 0;   // 驱动没报对齐：selftest 按 4096 分配 host 内存
        why[0] = 0;
        CHECK(s2a_gpu_mem_selftest(&dev, S2A_GPU_MEM_HOST_IMPORT, why, sizeof why) == 0);
        CHECK(strncmp(why, "ok kind=2", 9) == 0);
        CHECK(live_buffers() == 0 && live_memories() == 0);
    }
    case_end();

    case_begin("selftest_host_import_rejected");
    {
        fake_reset();
        dev_init(&dev);
        dev.external_memory_host_enabled = 1;
        dev.host_pointer_alignment = 64;
        g.reject_host_pointer = 1;   // 导入被驱动拒绝：selftest 报原因并释放自备 host 内存
        why[0] = 0;
        CHECK(s2a_gpu_mem_selftest(&dev, S2A_GPU_MEM_HOST_IMPORT, why, sizeof why) != 0);
        CHECK(strstr(why, "selftest create src failed") != NULL);
        CHECK(strstr(why, "rejected") != NULL);
        CHECK(g.create_buffer_n == 0);   // get_props 先拒，连 VkBuffer 都不建
        CHECK(g.copy_n == 0 && g.submit_n == 0);
        CHECK(live_buffers() == 0 && live_memories() == 0);
    }
    case_end();

    case_begin("selftest_fence_create_fails");
    {
        fake_reset();
        dev_init(&dev);
        g.fail_create_fence = 1;
        g.create_fence_result = VK_ERROR_OUT_OF_DEVICE_MEMORY;
        why[0] = 0;
        CHECK(s2a_gpu_mem_selftest(&dev, S2A_GPU_MEM_UPLOAD, why, sizeof why) != 0);
        CHECK(strstr(why, "vkCreateFence failed") != NULL);
        // 失败点之前已经建好 src/dst 与命令缓冲：必须全部回收。
        CHECK(g.cmd_allocate_n == 1 && g.cmd_free_n == 1);
        CHECK(g.fence_create_n == 1 && g.fence_destroy_n == 0);
        CHECK(g.submit_n == 0 && g.wait_n == 0);
        CHECK(g.unmap_n == 2 && g.destroy_buffer_n == 2 && g.free_n == 2);
        CHECK(g.device_idle_n == 0);   // 没提交过工作，不需要等 idle
        CHECK(live_buffers() == 0 && live_memories() == 0);
    }
    case_end();

    // 8) 带宽基准：HOST_IMPORT 以前恒失败，修复后必须返回正带宽 ---------------
    case_begin("bench_host_import_ok");
    {
        fake_reset();
        dev_init(&dev);
        dev.external_memory_host_enabled = 1;
        dev.host_pointer_alignment = 64;
        why[0] = 0;
        double mbs = s2a_gpu_mem_bench(&dev, S2A_GPU_MEM_HOST_IMPORT, 64 * 1024, why, sizeof why);
        CHECK(mbs > 0.0);
        CHECK(strstr(why, "kind=2") != NULL);
        CHECK(g.import_allocate_n == 1);
        CHECK(g.map_n == 0);      // 导入缓冲不需要 vkMapMemory
        CHECK(live_buffers() == 0 && live_memories() == 0);
        // 导入被拒时 bench 也要返回负值并给原因，且不残留对象。
        fake_reset();
        dev_init(&dev);
        dev.external_memory_host_enabled = 1;
        dev.host_pointer_alignment = 64;
        g.reject_host_pointer = 1;
        why[0] = 0;
        CHECK(s2a_gpu_mem_bench(&dev, S2A_GPU_MEM_HOST_IMPORT, 64 * 1024, why, sizeof why) < 0.0);
        CHECK(strstr(why, "bench create failed") != NULL);
        CHECK(live_buffers() == 0 && live_memories() == 0);
    }
    case_end();

    // 负对照：断言宏/计数链路本身必须能记到失败；否则上面的全 PASS 没有意义。
    {
        int before_fail = g_fail;
        int before_checks = g_checks;
        g_case_msg_n = 0;
        volatile int neg_a = 2, neg_b = 2;
        CHECK(neg_a + neg_b == 5);   // 故意错位：2+2 != 5
        int caught = g_fail == before_fail + 1 && g_checks == before_checks + 1;
        g_fail = before_fail;
        g_checks = before_checks;
        printf("  selfcheck %-38s %s\n", "deliberate_wrong_assertion",
               caught ? "PASS（负对照被捕获）" : "FAIL（负对照没被捕获）");
        if (!caught) g_fail++;
    }

    printf("\nvk-membuf: 用例 %d，检查 %d 项，失败 %d 项 → %s\n", g_cases, g_checks, g_fail,
           g_fail ? "红" : "通过");
    return g_fail ? 1 : 0;
}
