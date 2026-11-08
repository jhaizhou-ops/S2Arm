// GPU 内存层的后端实现：host import / AHardwareBuffer / dma-buf / 上传，四选一，按实测能力决定。
// 见 vk_membuf.h 的设计说明。这里只做「内存怎么来 + 同步怎么保」；绘制语义不在这里。
#include "vk_membuf.h"
#include "vk_device.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <dlfcn.h>
#include <errno.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/ioctl.h>
#include <unistd.h>

#if defined(__ANDROID__)
#include <android/hardware_buffer.h>

#include <sys/system_properties.h>
#endif

static int fail(char *why, size_t n, const char *text) {
    if (why && n) snprintf(why, n, "%s", text);
    return -1;
}

#if defined(__ANDROID__)
#include <android/log.h>
#define S2A_MLOG(...) __android_log_print(ANDROID_LOG_INFO, "S2Arm", __VA_ARGS__)
#else
#define S2A_MLOG(...) ((void)0)
#endif

static int prop_int(const char *name, int def) {
#if defined(__ANDROID__)
    char b[PROP_VALUE_MAX] = {0};
    return __system_property_get(name, b) > 0 ? atoi(b) : def;
#else
    const char *e = getenv(name);
    return e ? atoi(e) : def;
#endif
}

static struct s2a_gpu_mem_caps g_caps;
static int g_caps_valid;

const struct s2a_gpu_mem_caps *s2a_gpu_mem_caps_get(void) { return g_caps_valid ? &g_caps : NULL; }

// 按 usage 建缓冲 + 绑定内存的公共部分；kind 决定内存从哪来。
static int buf_alloc_host_visible(struct s2a_vk_device *d, VkDeviceSize size, VkBufferUsageFlags usage,
                                  struct s2a_gpu_buf *out, char *why, size_t why_size) {
    VkBufferCreateInfo bi = {0};
    bi.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
    bi.size = size;
    bi.usage = usage;
    bi.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    if (vkCreateBuffer(d->device, &bi, NULL, &out->buf) != VK_SUCCESS)
        return fail(why, why_size, "upload: vkCreateBuffer failed");
    VkMemoryRequirements mr;
    vkGetBufferMemoryRequirements(d->device, out->buf, &mr);
    VkMemoryPropertyFlags flags = 0;
    uint32_t mt = s2a_vk_memory_type(d, mr.memoryTypeBits,
        VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, &flags);
    if (mt == UINT32_MAX)
        mt = s2a_vk_memory_type(d, mr.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT, &flags);
    if (mt == UINT32_MAX) {
        vkDestroyBuffer(d->device, out->buf, NULL);
        out->buf = VK_NULL_HANDLE;
        return fail(why, why_size, "upload: no host-visible memory type");
    }
    VkMemoryAllocateInfo mai = {0};
    mai.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    mai.allocationSize = mr.size;
    mai.memoryTypeIndex = mt;
    if (vkAllocateMemory(d->device, &mai, NULL, &out->mem) != VK_SUCCESS) {
        vkDestroyBuffer(d->device, out->buf, NULL);
        out->buf = VK_NULL_HANDLE;
        return fail(why, why_size, "upload: vkAllocateMemory failed");
    }
    if (vkBindBufferMemory(d->device, out->buf, out->mem, 0) != VK_SUCCESS) {
        vkFreeMemory(d->device, out->mem, NULL);
        vkDestroyBuffer(d->device, out->buf, NULL);
        out->mem = VK_NULL_HANDLE; out->buf = VK_NULL_HANDLE;
        return fail(why, why_size, "upload: vkBindBufferMemory failed");
    }
    if (vkMapMemory(d->device, out->mem, 0, size, 0, &out->cpu) != VK_SUCCESS) out->cpu = NULL;
    out->mapped = out->cpu != NULL;
    out->coherent = (flags & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) != 0;
    out->size = size;
    out->alloc_size = mr.size;
    out->kind = S2A_GPU_MEM_UPLOAD;
    return 0;
}

// 导入已存在的 host 指针（guest 池直映射地址）：零拷贝路径。
static int buf_import_host(struct s2a_vk_device *d, const void *host, VkDeviceSize size,
                           VkBufferUsageFlags usage, struct s2a_gpu_buf *out, char *why, size_t why_size) {
    if (!host || !size) return fail(why, why_size, "host import: no pointer/size");
    if (!d->external_memory_host_enabled)
        return fail(why, why_size, "host import: not enabled on this device");
    PFN_vkGetMemoryHostPointerPropertiesEXT get_props = (PFN_vkGetMemoryHostPointerPropertiesEXT)
        vkGetDeviceProcAddr(d->device, "vkGetMemoryHostPointerPropertiesEXT");
    if (!get_props) return fail(why, why_size, "host import: vkGetMemoryHostPointerPropertiesEXT missing");
    VkMemoryHostPointerPropertiesEXT hp = {0};
    hp.sType = VK_STRUCTURE_TYPE_MEMORY_HOST_POINTER_PROPERTIES_EXT;
    if (get_props(d->device, VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT, host, &hp) != VK_SUCCESS)
        return fail(why, why_size, "host import: vkGetMemoryHostPointerPropertiesEXT rejected the pointer");
    VkDeviceSize align = d->host_pointer_alignment ? d->host_pointer_alignment : 1;
    if ((uintptr_t)host % align) return fail(why, why_size, "host import: pointer not aligned");
    VkExternalMemoryBufferCreateInfo ext = {0};
    ext.sType = VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_BUFFER_CREATE_INFO;
    ext.handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT;
    VkBufferCreateInfo bi = {0};
    bi.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
    bi.pNext = &ext;
    bi.size = size;
    bi.usage = usage;
    bi.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    if (vkCreateBuffer(d->device, &bi, NULL, &out->buf) != VK_SUCCESS)
        return fail(why, why_size, "host import: vkCreateBuffer failed");
    VkMemoryRequirements mr;
    vkGetBufferMemoryRequirements(d->device, out->buf, &mr);
    // 导入的分配大小必须是 mr.size：驱动 requirements 若大于用户给的区间，导入范围不够（越界读）。
    if (mr.size > size) {
        vkDestroyBuffer(d->device, out->buf, NULL); out->buf = VK_NULL_HANDLE;
        return fail(why, why_size, "host import: driver requirements exceed the imported range");
    }
    VkMemoryPropertyFlags flags = 0;
    uint32_t mt = s2a_vk_memory_type(d, mr.memoryTypeBits & hp.memoryTypeBits, 0, &flags);
    if (mt == UINT32_MAX) {
        vkDestroyBuffer(d->device, out->buf, NULL); out->buf = VK_NULL_HANDLE;
        return fail(why, why_size, "host import: no shared memory type");
    }
    VkImportMemoryHostPointerInfoEXT imp = {0};
    imp.sType = VK_STRUCTURE_TYPE_IMPORT_MEMORY_HOST_POINTER_INFO_EXT;
    imp.handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT;
    imp.pHostPointer = (void *)host;
    VkMemoryAllocateInfo mai = {0};
    mai.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    mai.allocationSize = mr.size;
    mai.memoryTypeIndex = mt;
    mai.pNext = &imp;
    if (vkAllocateMemory(d->device, &mai, NULL, &out->mem) != VK_SUCCESS) {
        vkDestroyBuffer(d->device, out->buf, NULL); out->buf = VK_NULL_HANDLE;
        return fail(why, why_size, "host import: vkAllocateMemory(import) failed");
    }
    if (vkBindBufferMemory(d->device, out->buf, out->mem, 0) != VK_SUCCESS) {
        vkFreeMemory(d->device, out->mem, NULL);
        vkDestroyBuffer(d->device, out->buf, NULL);
        out->mem = VK_NULL_HANDLE; out->buf = VK_NULL_HANDLE;
        return fail(why, why_size, "host import: vkBindBufferMemory failed");
    }
    out->cpu = (void *)host;      // 导入的缓冲 CPU 侧就是原指针，本来就不用再映射
    out->mapped = 1;
    out->coherent = (flags & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) != 0;
    out->size = size;
    out->alloc_size = mr.size;
    out->kind = S2A_GPU_MEM_HOST_IMPORT;
    return 0;
}

#if defined(__ANDROID__)
// AHB 共享后备页：内存由 gralloc 分配，CPU 经 AHardwareBuffer_lock 访问，Vulkan 导入同一块页。
static int buf_import_ahb(struct s2a_vk_device *d, AHardwareBuffer *ahb, VkDeviceSize size,
                          VkBufferUsageFlags usage, struct s2a_gpu_buf *out, char *why, size_t why_size) {
    PFN_vkGetAndroidHardwareBufferPropertiesANDROID get_ahb = (PFN_vkGetAndroidHardwareBufferPropertiesANDROID)
        vkGetDeviceProcAddr(d->device, "vkGetAndroidHardwareBufferPropertiesANDROID");
    if (!get_ahb) return fail(why, why_size, "ahb: vkGetAndroidHardwareBufferPropertiesANDROID missing");
    VkAndroidHardwareBufferPropertiesANDROID props = {0};
    props.sType = VK_STRUCTURE_TYPE_ANDROID_HARDWARE_BUFFER_PROPERTIES_ANDROID;
    if (get_ahb(d->device, ahb, &props) != VK_SUCCESS)
        return fail(why, why_size, "ahb: vkGetAndroidHardwareBufferPropertiesANDROID failed");
    {
    VkPhysicalDeviceExternalBufferInfo ebi = {0};
    ebi.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_BUFFER_INFO;
    ebi.usage = usage;
    ebi.handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_ANDROID_HARDWARE_BUFFER_BIT_ANDROID;
    VkExternalBufferProperties ebp = {0};
    ebp.sType = VK_STRUCTURE_TYPE_EXTERNAL_BUFFER_PROPERTIES;
    vkGetPhysicalDeviceExternalBufferProperties(d->physical, &ebi, &ebp);
    if (!(ebp.externalMemoryProperties.externalMemoryFeatures & VK_EXTERNAL_MEMORY_FEATURE_IMPORTABLE_BIT))
        return fail(why, why_size, "ahb: buffer import not supported for this usage");
    }
    AHardwareBuffer_Desc desc = {0};
    AHardwareBuffer_describe(ahb, &desc);
    (void)desc;
    // 导入外部内存的 buffer 必须声明 handleTypes，否则 vkGetBufferMemoryRequirements 给出的
    // memoryTypeBits 不是“外部可导入”的那一组（本机第一次就是在这里得到空交集）。
    VkExternalMemoryBufferCreateInfo ext = {0};
    ext.sType = VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_BUFFER_CREATE_INFO;
    ext.handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_ANDROID_HARDWARE_BUFFER_BIT_ANDROID;
    VkBufferCreateInfo bi = {0};
    bi.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
    bi.pNext = &ext;
    bi.size = size;
    bi.usage = usage;
    bi.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    if (vkCreateBuffer(d->device, &bi, NULL, &out->buf) != VK_SUCCESS)
        return fail(why, why_size, "ahb: vkCreateBuffer failed");
    VkMemoryRequirements mr;
    vkGetBufferMemoryRequirements(d->device, out->buf, &mr);
    VkMemoryPropertyFlags flags = 0;
    uint32_t bits = mr.memoryTypeBits & props.memoryTypeBits;
    uint32_t mt = s2a_vk_memory_type(d, bits, 0, &flags);
    if (mt == UINT32_MAX) {
        char t[160];
        snprintf(t, sizeof t, "ahb: no shared memory type (buffer=%#x ahb=%#x intersect=%#x size=%llu/%llu)",
                 mr.memoryTypeBits, props.memoryTypeBits, bits,
                 (unsigned long long)mr.size, (unsigned long long)props.allocationSize);
        vkDestroyBuffer(d->device, out->buf, NULL); out->buf = VK_NULL_HANDLE;
        return fail(why, why_size, t);
    }
    VkMemoryDedicatedAllocateInfo ded = {0};
    ded.sType = VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO;
    ded.buffer = out->buf;
    VkImportAndroidHardwareBufferInfoANDROID imp = {0};
    imp.sType = VK_STRUCTURE_TYPE_IMPORT_ANDROID_HARDWARE_BUFFER_INFO_ANDROID;
    imp.buffer = ahb;
    ded.pNext = &imp;
    VkMemoryAllocateInfo mai = {0};
    mai.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    mai.allocationSize = props.allocationSize ? props.allocationSize : mr.size;
    mai.memoryTypeIndex = mt;
    mai.pNext = &ded;
    if (vkAllocateMemory(d->device, &mai, NULL, &out->mem) != VK_SUCCESS) {
        vkDestroyBuffer(d->device, out->buf, NULL); out->buf = VK_NULL_HANDLE;
        return fail(why, why_size, "ahb: vkAllocateMemory(import) failed");
    }
    if (vkBindBufferMemory(d->device, out->buf, out->mem, 0) != VK_SUCCESS) {
        vkFreeMemory(d->device, out->mem, NULL);
        vkDestroyBuffer(d->device, out->buf, NULL);
        out->mem = VK_NULL_HANDLE; out->buf = VK_NULL_HANDLE;
        return fail(why, why_size, "ahb: vkBindBufferMemory failed");
    }
    void *cpu = NULL;
    if (AHardwareBuffer_lock(ahb, AHARDWAREBUFFER_USAGE_CPU_WRITE_OFTEN, -1, NULL, &cpu) == 0) {
        out->cpu = cpu;
        out->mapped = 1;
    }
    // AHB 后备页的 CPU 与 GPU 视图是否一致由驱动/gralloc 决定，不能按“高通的 AHB 一定一致”假设：
    // 交给 selftest 实测；这里先按非一致处理，调用者写完后显式 flush。
    out->coherent = 0;
    out->ahb = ahb;   // 所有权交给 out：销毁时 release
    out->size = size;
    out->alloc_size = props.allocationSize ? props.allocationSize : mr.size;
    out->kind = S2A_GPU_MEM_AHB;
    return 0;
}

// 新建一块 AHB 并导入：内存由 gralloc 分配，CPU 与 GPU 共用同一块后备页。
static int buf_alloc_ahb(struct s2a_vk_device *d, VkDeviceSize size, VkBufferUsageFlags usage,
                         struct s2a_gpu_buf *out, char *why, size_t why_size) {
    AHardwareBuffer_Desc desc = {0};
    desc.width = (uint32_t)size;
    desc.height = 1;
    desc.layers = 1;
    desc.format = AHARDWAREBUFFER_FORMAT_BLOB;
    desc.usage = AHARDWAREBUFFER_USAGE_CPU_WRITE_OFTEN | AHARDWAREBUFFER_USAGE_CPU_READ_OFTEN |
                 AHARDWAREBUFFER_USAGE_GPU_DATA_BUFFER;
    if (!AHardwareBuffer_isSupported(&desc))
        return fail(why, why_size, "ahb: BLOB description not supported");
    AHardwareBuffer *ahb = NULL;
    if (AHardwareBuffer_allocate(&desc, &ahb) != 0 || !ahb)
        return fail(why, why_size, "ahb: AHardwareBuffer_allocate failed");
    int rc = buf_import_ahb(d, ahb, size, usage, out, why, why_size);
    if (rc != 0) { AHardwareBuffer_release(ahb); return rc; }
    return 0;   // buf_import_ahb 已把 ahb 交给 out，由 s2a_gpu_buf_destroy 释放
}
#endif

int s2a_gpu_mem_probe(struct s2a_vk_device *device, struct s2a_gpu_mem_caps *caps,
                      char *why, size_t why_size) {
    if (!device || !device->device) return fail(why, why_size, "no device");
    if (!caps) return fail(why, why_size, "no caps");
    memset(caps, 0, sizeof *caps);
    caps->shared_enabled = prop_int("debug.s2a.mem_shared", 0);
    caps->host_import = device->external_memory_host_enabled;
    caps->host_align = device->host_pointer_alignment;
    caps->chosen = S2A_GPU_MEM_UPLOAD;
#if defined(__ANDROID__)
    {
        // 只查 advertise；能不能用由 selftest 决定。
        uint32_t n = 0;
        if (vkEnumerateDeviceExtensionProperties(device->physical, NULL, &n, NULL) == VK_SUCCESS && n) {
            VkExtensionProperties *ext = calloc(n, sizeof *ext);
            if (ext && vkEnumerateDeviceExtensionProperties(device->physical, NULL, &n, ext) == VK_SUCCESS) {
                for (uint32_t i = 0; i < n; i++) {
                    if (!strcmp(ext[i].extensionName, "VK_ANDROID_external_memory_android_hardware_buffer"))
                        caps->ahb = 1;
                    if (!strcmp(ext[i].extensionName, "VK_EXT_external_memory_dma_buf"))
                        caps->dmabuf = 1;
                }
            }
            free(ext);
        }
    }
#endif
    g_caps = *caps;
    g_caps_valid = 1;
    return 0;
}

int s2a_gpu_buf_create(struct s2a_vk_device *device, VkDeviceSize size, VkBufferUsageFlags usage,
                       int kind, struct s2a_gpu_buf *out, char *why, size_t why_size) {
    if (!device || !device->device || !out) return fail(why, why_size, "bad arguments");
    memset(out, 0, sizeof *out);
    out->buf = VK_NULL_HANDLE; out->mem = VK_NULL_HANDLE;
    if (kind == S2A_GPU_MEM_NONE) kind = (g_caps_valid && g_caps.shared_enabled) ? g_caps.chosen : S2A_GPU_MEM_UPLOAD;
#if defined(__ANDROID__)
    if (kind == S2A_GPU_MEM_AHB) return buf_alloc_ahb(device, size, usage, out, why, why_size);
#endif
    if (kind == S2A_GPU_MEM_HOST_IMPORT)
        return fail(why, why_size, "host import needs an existing pointer: use s2a_gpu_buf_import");
    out->kind = S2A_GPU_MEM_UPLOAD;
    return buf_alloc_host_visible(device, size, usage, out, why, why_size);
}

int s2a_gpu_buf_import(struct s2a_vk_device *device, const void *host, VkDeviceSize size,
                       VkBufferUsageFlags usage, struct s2a_gpu_buf *out, char *why, size_t why_size) {
    if (!device || !device->device || !out) return fail(why, why_size, "bad arguments");
    memset(out, 0, sizeof *out);
    out->buf = VK_NULL_HANDLE; out->mem = VK_NULL_HANDLE;
    if (!host || !size) return fail(why, why_size, "host import: no pointer/size");
    return buf_import_host(device, host, size, usage, out, why, why_size);
}

#if defined(__ANDROID__)
// AHB 的 CPU 视图只在 unlock 之前有效：任何 unlock 之后必须重新 lock，并**更新 b->cpu**
// （驱动不保证两次 lock 返回同一地址；旧实现 unlock 后把悬空指针留在 b->cpu 里）。
static int ahb_relock(struct s2a_gpu_buf *b) {
    void *cpu = NULL;
    b->mapped = 0;
    b->cpu = NULL;
    if (!b->ahb) return -1;
    if (AHardwareBuffer_lock((AHardwareBuffer *)b->ahb,
                             AHARDWAREBUFFER_USAGE_CPU_WRITE_OFTEN | AHARDWAREBUFFER_USAGE_CPU_READ_OFTEN,
                             -1, NULL, &cpu) != 0 || !cpu)
        return -1;
    b->cpu = cpu;
    b->mapped = 1;
    return 0;
}
// 提交 CPU 写入：unlock 让驱动收口，然后重新 lock 保持“持有 CPU 映射”这个不变量。
static void ahb_flush_relock(struct s2a_gpu_buf *b) {
    if (!b->ahb || !b->mapped) return;
    AHardwareBuffer_unlock((AHardwareBuffer *)b->ahb, NULL);
    (void)ahb_relock(b);
}
#endif

void s2a_gpu_buf_flush(struct s2a_vk_device *device, const struct s2a_gpu_buf *b,
                       VkDeviceSize off, VkDeviceSize len) {
    if (!device || !b || !b->mem || b->coherent) return;
#if defined(__ANDROID__)
    if (b->kind == S2A_GPU_MEM_AHB) {
        struct s2a_gpu_buf *w = (struct s2a_gpu_buf *)b;   // cpu/mapped 是映射状态的缓存，要更新
        ahb_flush_relock(w);
        return;
    }
#endif
    VkMappedMemoryRange r = {0};
    r.sType = VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE;
    r.memory = b->mem;
    r.offset = 0;
    r.size = VK_WHOLE_SIZE;
    (void)off; (void)len;
    vkFlushMappedMemoryRanges(device->device, 1, &r);
}

void s2a_gpu_buf_invalidate(struct s2a_vk_device *device, const struct s2a_gpu_buf *b,
                            VkDeviceSize off, VkDeviceSize len) {
    if (!device || !b) return;
#if defined(__ANDROID__)
    if (b->kind == S2A_GPU_MEM_AHB) {
        // GPU 写完、CPU 要读：重新 lock 才能看到内容（旧实现走 vkInvalidateMappedMemoryRanges，
        // 对 AHB 没有意义，因为这条内存根本没有 vkMapMemory 的映射）。
        struct s2a_gpu_buf *w = (struct s2a_gpu_buf *)b;
        if (!b->coherent) ahb_flush_relock(w);
        return;
    }
#endif
    if (!b->mem || b->coherent) return;
    (void)off; (void)len;
    VkMappedMemoryRange r = {0};
    r.sType = VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE;
    r.memory = b->mem;
    r.offset = 0;
    r.size = VK_WHOLE_SIZE;
    vkInvalidateMappedMemoryRanges(device->device, 1, &r);
}

void s2a_gpu_buf_destroy(struct s2a_vk_device *device, struct s2a_gpu_buf *b) {
    if (!device || !b) return;
#if defined(__ANDROID__)
    if (b->kind == S2A_GPU_MEM_AHB) {
        // 顺序：unlock（提交挂起的 CPU 写）→ close dma-buf fd → release AHB → 再销毁 Vk 对象。
        if (b->ahb && b->mapped) {
            AHardwareBuffer_unlock((AHardwareBuffer *)b->ahb, NULL);
            b->mapped = 0; b->cpu = NULL;
        }
        if (b->fd > 0) { close(b->fd); b->fd = -1; }   // 旧实现从不 close：长跑会漏 fd
        if (b->ahb) { AHardwareBuffer_release((AHardwareBuffer *)b->ahb); b->ahb = NULL; }
    }
#endif
    if (b->kind == S2A_GPU_MEM_UPLOAD && b->mem && b->cpu) {
        vkUnmapMemory(device->device, b->mem);
        b->cpu = NULL;
    }
    if (b->buf) vkDestroyBuffer(device->device, b->buf, NULL);
    if (b->mem) vkFreeMemory(device->device, b->mem, NULL);
    memset(b, 0, sizeof *b);
}

// 后端自检：CPU 写共享页 → GPU 拷到普通缓冲 → CPU 比对；反向再验一次 GPU 写、CPU 读。
int s2a_gpu_mem_selftest(struct s2a_vk_device *device, int kind, char *why, size_t why_size) {
    if (!device || !device->device) return fail(why, why_size, "no device");
    const VkDeviceSize size = 64 * 1024;
    const VkBufferUsageFlags usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT |
                                     VK_BUFFER_USAGE_VERTEX_BUFFER_BIT | VK_BUFFER_USAGE_INDEX_BUFFER_BIT |
                                     VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT;
    struct s2a_gpu_buf src = {0}, dst = {0};
    void *host_mem = NULL;   // HOST_IMPORT 自检的源内存（导入路径没有“创建”，要自己准备一块）
    char inner[192] = "";
    char diag[192] = "";
    if (kind == S2A_GPU_MEM_AHB || kind == S2A_GPU_MEM_HOST_IMPORT) {
        VkPhysicalDeviceExternalBufferInfo ebi = {0};
        ebi.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_BUFFER_INFO;
        ebi.usage = usage;
        ebi.handleType = kind == S2A_GPU_MEM_AHB
            ? VK_EXTERNAL_MEMORY_HANDLE_TYPE_ANDROID_HARDWARE_BUFFER_BIT_ANDROID
            : VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT;
        VkExternalBufferProperties ebp = {0};
        ebp.sType = VK_STRUCTURE_TYPE_EXTERNAL_BUFFER_PROPERTIES;
        vkGetPhysicalDeviceExternalBufferProperties(device->physical, &ebi, &ebp);
        snprintf(diag, sizeof diag, "ext props: features=%#x compatible=%#x",
                 ebp.externalMemoryProperties.externalMemoryFeatures,
                 ebp.externalMemoryProperties.compatibleHandleTypes);
    }
    int created;
    if (kind == S2A_GPU_MEM_HOST_IMPORT) {
        // 导入路径没有“创建”这一步：自己分配一块满足 minImportedHostPointerAlignment 的 host 内存再导入。
        // （以前这里误用 s2a_gpu_buf_create(HOST_IMPORT)，create 无条件拒绝 → 导出自检恒失败。）
        VkDeviceSize align = device->host_pointer_alignment ? device->host_pointer_alignment : 4096;
        if (align < (VkDeviceSize)sizeof(void *)) align = (VkDeviceSize)sizeof(void *);   // posix_memalign 下限
        if (posix_memalign(&host_mem, (size_t)align, (size_t)size) != 0 || !host_mem) {
            host_mem = NULL;
            created = fail(inner, sizeof inner, "selftest: host allocation for import failed");
        } else {
            memset(host_mem, 0, (size_t)size);
            created = s2a_gpu_buf_import(device, host_mem, size, usage, &src, inner, sizeof inner);
        }
    } else {
        created = s2a_gpu_buf_create(device, size, usage, kind, &src, inner, sizeof inner);
    }
    if (created) {
        char t[320];
        // inner/diag 各 192 字节，全量拼进来会超过 t（320）——宿主 gcc 以 format-truncation 判红。
        snprintf(t, sizeof t, "selftest create src failed: %.140s [%.140s]", inner, diag);
        free(host_mem);
        return fail(why, why_size, t);
    }
    if (src.kind != kind) {
        char t[160];
        snprintf(t, sizeof t, "selftest backend mismatch: asked %d got %d", kind, src.kind);
        s2a_gpu_buf_destroy(device, &src);
        free(host_mem);
        return fail(why, why_size, t);
    }
    if (buf_alloc_host_visible(device, size, usage | VK_BUFFER_USAGE_TRANSFER_SRC_BIT, &dst, inner, sizeof inner)) {
        char t[256];
        snprintf(t, sizeof t, "selftest create dst failed: %s", inner);
        s2a_gpu_buf_destroy(device, &src);
        free(host_mem);
        return fail(why, why_size, t);
    }
    if (!src.cpu) {
        s2a_gpu_buf_destroy(device, &src);
        s2a_gpu_buf_destroy(device, &dst);
        free(host_mem);
        return fail(why, why_size, "selftest: shared backend gave no CPU mapping");
    }
    // 1) CPU 写图案 → GPU 读
    for (VkDeviceSize i = 0; i < size; i++) ((uint8_t *)src.cpu)[i] = (uint8_t)(i * 7u + 3u);
    s2a_gpu_buf_flush(device, &src, 0, size);
    for (VkDeviceSize i = 0; i < size; i++) ((uint8_t *)dst.cpu)[i] = 0;

    VkCommandBufferAllocateInfo cai = {0};
    cai.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    cai.commandPool = device->command_pool;
    cai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    cai.commandBufferCount = 1;
    VkCommandBuffer cmd = VK_NULL_HANDLE;
    if (vkAllocateCommandBuffers(device->device, &cai, &cmd) != VK_SUCCESS) {
        s2a_gpu_buf_destroy(device, &src);
        s2a_gpu_buf_destroy(device, &dst);
        free(host_mem);
        return fail(why, why_size, "selftest: vkAllocateCommandBuffers failed");
    }
    VkFenceCreateInfo fci = {0};
    fci.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
    VkFence fence = VK_NULL_HANDLE;
    if (vkCreateFence(device->device, &fci, NULL, &fence) != VK_SUCCESS) {
        vkFreeCommandBuffers(device->device, device->command_pool, 1, &cmd);
        s2a_gpu_buf_destroy(device, &src);
        s2a_gpu_buf_destroy(device, &dst);
        free(host_mem);
        return fail(why, why_size, "selftest: vkCreateFence failed");
    }

    VkCommandBufferBeginInfo cbi = {0};
    cbi.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    cbi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    vkBeginCommandBuffer(cmd, &cbi);
    {
        VkBufferMemoryBarrier bb = {0};
        bb.sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER;
        bb.srcAccessMask = VK_ACCESS_HOST_WRITE_BIT;
        bb.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
        bb.srcQueueFamilyIndex = bb.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        bb.buffer = src.buf; bb.offset = 0; bb.size = VK_WHOLE_SIZE;
        vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_HOST_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
                             0, 0, NULL, 1, &bb, 0, NULL);
    }
    VkBufferCopy region = {0, 0, size};
    vkCmdCopyBuffer(cmd, src.buf, dst.buf, 1, &region);
    vkEndCommandBuffer(cmd);
    int rc = -1;
    char text[192] = "";
    VkSubmitInfo si = {0};
    si.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
    si.commandBufferCount = 1;
    si.pCommandBuffers = &cmd;
    if (vkQueueSubmit(device->queue, 1, &si, fence) != VK_SUCCESS) {
        snprintf(text, sizeof text, "selftest: vkQueueSubmit failed");
        goto done;
    }
    if (vkWaitForFences(device->device, 1, &fence, VK_TRUE, 2000000000ull) != VK_SUCCESS) {
        snprintf(text, sizeof text, "selftest: fence timeout");
        goto done;
    }
    s2a_gpu_buf_invalidate(device, &dst, 0, size);
    {
        int bad = 0;
        for (VkDeviceSize i = 0; i < size; i++)
            if (((uint8_t *)dst.cpu)[i] != (uint8_t)(i * 7u + 3u)) { bad = 1; break; }
        if (bad) { snprintf(text, sizeof text, "selftest: GPU read mismatch (CPU wrote into shared page, GPU saw different bytes)"); goto done; }
    }
    // 2) GPU 写 → CPU 读：把 dst（CPU 写图案）拷回 src，CPU 侧比对 src。
    for (VkDeviceSize i = 0; i < size; i++) ((uint8_t *)dst.cpu)[i] = (uint8_t)(255u - (uint8_t)(i * 13u));
    s2a_gpu_buf_flush(device, &dst, 0, size);
    vkResetCommandBuffer(cmd, 0);
    vkBeginCommandBuffer(cmd, &cbi);
    vkCmdCopyBuffer(cmd, dst.buf, src.buf, 1, &region);
    vkEndCommandBuffer(cmd);
    vkResetFences(device->device, 1, &fence);
    if (vkQueueSubmit(device->queue, 1, &si, fence) != VK_SUCCESS) {
        snprintf(text, sizeof text, "selftest: vkQueueSubmit(2) failed");
        goto done;
    }
    if (vkWaitForFences(device->device, 1, &fence, VK_TRUE, 2000000000ull) != VK_SUCCESS) {
        snprintf(text, sizeof text, "selftest: fence timeout(2)");
        goto done;
    }
    s2a_gpu_buf_invalidate(device, &src, 0, size);
    {
        int bad = 0;
        for (VkDeviceSize i = 0; i < size; i++)
            if (((uint8_t *)src.cpu)[i] != (uint8_t)(255u - (uint8_t)(i * 13u))) { bad = 1; break; }
        if (bad) { snprintf(text, sizeof text, "selftest: CPU read mismatch (GPU wrote, CPU saw different bytes; cache maintenance needed)"); goto done; }
    }
    snprintf(text, sizeof text, "ok kind=%d size=%llu coherent=%d", src.kind, (unsigned long long)size, src.coherent);
    rc = 0;
done:
    vkDeviceWaitIdle(device->device);
    if (fence) vkDestroyFence(device->device, fence, NULL);
    if (cmd) vkFreeCommandBuffers(device->device, device->command_pool, 1, &cmd);
    s2a_gpu_buf_destroy(device, &src);
    s2a_gpu_buf_destroy(device, &dst);
    free(host_mem);
    if (why && why_size) snprintf(why, why_size, "%s", text);
    return rc;
}

// 带宽基准：这条共享路径当「guest 可写内存」用时，CPU 写入与读回有多快。
// 为什么必须量：AHB/dma-buf 的 CPU 映射常常是不可缓存或写合并的，guest 每次写池子都要付这个代价；
// 若比普通内存慢一个数量级，即便省掉 memcpy 也是净亏。返回 MB/s（>=0），失败写 why。
double s2a_gpu_mem_bench(struct s2a_vk_device *device, int kind, size_t bytes,
                         char *why, size_t why_size) {
    struct s2a_gpu_buf b = {0};
    void *host_mem = NULL;
    char inner[192] = "";
    const VkBufferUsageFlags bench_usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT |
                                           VK_BUFFER_USAGE_VERTEX_BUFFER_BIT | VK_BUFFER_USAGE_INDEX_BUFFER_BIT |
                                           VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT;
    int created;
    if (kind == S2A_GPU_MEM_HOST_IMPORT) {
        // 与 selftest 同理：导入没有“创建”，自己准备一块对齐的 host 内存（以前这里恒失败）。
        VkDeviceSize align = device->host_pointer_alignment ? device->host_pointer_alignment : 4096;
        if (align < (VkDeviceSize)sizeof(void *)) align = (VkDeviceSize)sizeof(void *);   // posix_memalign 下限
        if (posix_memalign(&host_mem, (size_t)align, bytes) != 0 || !host_mem) {
            host_mem = NULL;
            created = -1;
            snprintf(inner, sizeof inner, "bench: host allocation for import failed");
        } else {
            created = s2a_gpu_buf_import(device, host_mem, (VkDeviceSize)bytes, bench_usage, &b, inner, sizeof inner);
        }
    } else {
        created = s2a_gpu_buf_create(device, (VkDeviceSize)bytes, bench_usage, kind, &b, inner, sizeof inner);
    }
    if (created) {
        free(host_mem);
        if (why && why_size) snprintf(why, why_size, "bench create failed: %s", inner);
        return -1.0;
    }
    if (!b.cpu) {
        s2a_gpu_buf_destroy(device, &b);
        free(host_mem);
        if (why && why_size) snprintf(why, why_size, "bench: no cpu mapping");
        return -1.0;
    }
    static uint8_t pattern[4096];
    for (size_t i = 0; i < sizeof pattern; i++) pattern[i] = (uint8_t)(i * 31u + 7u);
    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (size_t off = 0; off < bytes; off += sizeof pattern) {
        // bytes 不是 pattern 的整数倍时最后一块要截短，否则写越界（HOST_IMPORT 分配的正好是 bytes）。
        size_t n = bytes - off < sizeof pattern ? bytes - off : sizeof pattern;
        memcpy((uint8_t *)b.cpu + off, pattern, n);
    }
    s2a_gpu_buf_flush(device, &b, 0, bytes);
    clock_gettime(CLOCK_MONOTONIC, &t1);
    double sec = (double)(t1.tv_sec - t0.tv_sec) + (double)(t1.tv_nsec - t0.tv_nsec) * 1e-9;
    // 读回一遍（防止被优化掉，也给出读带宽）
    volatile uint64_t sum = 0;
    for (size_t off = 0; off < bytes; off += 64) sum += ((volatile uint8_t *)b.cpu)[off];
    s2a_gpu_buf_destroy(device, &b);
    free(host_mem);
    if (sec <= 0) sec = 1e-9;
    if (why && why_size) snprintf(why, why_size, "kind=%d bytes=%zu sum=%llu", kind, bytes,
                                  (unsigned long long)sum);
    return (double)bytes / 1048576.0 / sec;
}

#if defined(__ANDROID__)
// fd/偏移只有一处取法（原生 handle 的 SCM_RIGHTS payload）：别名自检与 map_at 共用，避免两套口径。
int s2a_ahb_fd_acquire(void *ahb_ptr, int *out_fd, int64_t *out_off, char *why, size_t why_size);
// AHB 别名自检：验证「同一块 AHB 后备页可以同时被 guest 地址（mmap fd）和 Vulkan 使用」。
// 这是 guest 与 GPU 共用后备页的前提：guest 虚拟地址映射到同一个 fd 的页，游戏写池子就是写显存。
//
// 取 fd 不走隐藏 API（AHardwareBuffer_getNativeHandle 在 NDK/运行时都不可靠：dlsym 拿到的符号
// 调用后返回垃圾值），改用公开的 AHardwareBuffer_sendHandleToUnixSocket 把 native handle 发到
// socketpair，再用 recvmsg 自己取 SCM_RIGHTS fd 与偏移——公开 API，语义明确。
static int ahb_alias_probe(struct s2a_vk_device *d, char *why, size_t why_size) {
    const size_t size = 1u << 20;
    AHardwareBuffer_Desc desc = {0};
    desc.width = (uint32_t)size; desc.height = 1; desc.layers = 1;
    desc.format = AHARDWAREBUFFER_FORMAT_BLOB;
    desc.usage = AHARDWAREBUFFER_USAGE_CPU_WRITE_OFTEN | AHARDWAREBUFFER_USAGE_CPU_READ_OFTEN |
                 AHARDWAREBUFFER_USAGE_GPU_DATA_BUFFER;
    AHardwareBuffer *ahb = NULL;
    if (AHardwareBuffer_allocate(&desc, &ahb) != 0 || !ahb) return fail(why, why_size, "alias: allocate failed");
    int fd = -1; int64_t off = 0;
    char inner[192] = "";
    int rc = -1;
    char text[288] = "";
    void *reserved = MAP_FAILED, *guest_map = MAP_FAILED;
    struct s2a_gpu_buf shared = {0}, dst = {0};
    VkCommandBuffer cmd = VK_NULL_HANDLE;
    VkFence fence = VK_NULL_HANDLE;
    if (s2a_ahb_fd_acquire(ahb, &fd, &off, inner, sizeof inner) != 0) {
        snprintf(text, sizeof text, "%s", inner);
        goto done;
    }
    // 1) 把 fd 映射到一个**指定地址**（预留一段再 MAP_FIXED 覆盖）：这是“guest 虚拟地址就是显存”的机制。
    reserved = mmap(NULL, size, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (reserved == MAP_FAILED) { snprintf(text, sizeof text, "alias: reserve failed errno=%d", errno); goto done; }
    guest_map = mmap(reserved, size, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_FIXED, fd, (off_t)off);
    if (guest_map == MAP_FAILED || guest_map != reserved) {
        snprintf(text, sizeof text, "alias: MAP_FIXED overlay failed (got %p want %p errno=%d)",
                 guest_map, reserved, errno);
        guest_map = MAP_FAILED;
        goto done;
    }
    // 2) 数据别名：经 lock 写 vs 经 guest 地址写/读，必须互相看见。
    void *cpu_lock = NULL;
    if (AHardwareBuffer_lock(ahb, AHARDWAREBUFFER_USAGE_CPU_WRITE_OFTEN, -1, NULL, &cpu_lock) != 0 || !cpu_lock) {
        snprintf(text, sizeof text, "alias: AHardwareBuffer_lock failed");
        goto done;
    }
    memset(cpu_lock, 0xA5, size);
    AHardwareBuffer_unlock(ahb, NULL);
    AHardwareBuffer_lock(ahb, AHARDWAREBUFFER_USAGE_CPU_READ_OFTEN, -1, NULL, &cpu_lock);
    int same = memcmp(guest_map, cpu_lock, size) == 0;
    for (size_t i = 0; i < size; i++) ((uint8_t *)guest_map)[i] = (uint8_t)(i * 11u + 5u);
    int same2 = memcmp(guest_map, cpu_lock, size) == 0;
    if (!same || !same2) {
        snprintf(text, sizeof text, "alias: data not shared (lock->guest=%d guest->lock=%d)", same, same2);
        goto done;
    }
    // 3) GPU 侧：把同一块 AHB 导入成 VkBuffer，GPU 拷到普通缓冲再比对——
    //    只经 guest 地址写过，没有任何 memcpy，GPU 必须读到同样的字节。
    {
        char iw[160] = "";
        if (buf_import_ahb(d, ahb, size,
                VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_VERTEX_BUFFER_BIT |
                VK_BUFFER_USAGE_INDEX_BUFFER_BIT | VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
                &shared, iw, sizeof iw) != 0) {
            snprintf(text, sizeof text, "alias: import into Vulkan failed: %s", iw);
            goto done;
        }
        shared.ahb = NULL;   // 这块 AHB 由本函数释放，不让 buf 再 release 一次
        if (buf_alloc_host_visible(d, size,
                VK_BUFFER_USAGE_TRANSFER_DST_BIT | VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT, &dst, iw, sizeof iw) != 0) {
            snprintf(text, sizeof text, "alias: dst buffer failed: %s", iw);
            goto done;
        }
        VkCommandBufferAllocateInfo cai = {0};
        cai.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        cai.commandPool = d->command_pool;
        cai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        cai.commandBufferCount = 1;
        if (vkAllocateCommandBuffers(d->device, &cai, &cmd) != VK_SUCCESS) {
            snprintf(text, sizeof text, "alias: vkAllocateCommandBuffers failed");
            goto done;
        }
        VkFenceCreateInfo fci = {0};
        fci.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
        if (vkCreateFence(d->device, &fci, NULL, &fence) != VK_SUCCESS) {
            snprintf(text, sizeof text, "alias: vkCreateFence failed");
            goto done;
        }
        VkCommandBufferBeginInfo cbi = {0};
        cbi.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        cbi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        vkBeginCommandBuffer(cmd, &cbi);
        VkBufferCopy region = {0, 0, size};
        vkCmdCopyBuffer(cmd, shared.buf, dst.buf, 1, &region);
        vkEndCommandBuffer(cmd);
        VkSubmitInfo si = {0};
        si.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
        si.commandBufferCount = 1;
        si.pCommandBuffers = &cmd;
        if (vkQueueSubmit(d->queue, 1, &si, fence) != VK_SUCCESS ||
            vkWaitForFences(d->device, 1, &fence, VK_TRUE, 2000000000ull) != VK_SUCCESS) {
            snprintf(text, sizeof text, "alias: submit/wait failed");
            goto done;
        }
        s2a_gpu_buf_invalidate(d, &dst, 0, size);
        // 注意：到这里还没有对 AHB 做过任何 unlock/sync——就是要看“不做 cache 维护”时 GPU 能否读到 CPU 写入。
        int gpu_ok = 1;
        for (size_t i = 0; i < size; i++)
            if (((uint8_t *)dst.cpu)[i] != (uint8_t)(i * 11u + 5u)) { gpu_ok = 0; break; }
        if (!gpu_ok) {
            snprintf(text, sizeof text, "alias: GPU read mismatch WITHOUT cache sync (sync required)");
            goto done;
        }
    }
    {
        void *lu = NULL;
        if (AHardwareBuffer_lock(ahb, AHARDWAREBUFFER_USAGE_CPU_WRITE_OFTEN, -1, NULL, &lu) == 0)
            AHardwareBuffer_unlock(ahb, NULL);
    }
    snprintf(text, sizeof text, "alias: ok fd=%d off=%lld lock<->guest=%d/%d gpu_reads_guest_writes_no_sync=1",
             fd, (long long)off, same, same2);
    rc = 0;
done:
    if (fence) { vkDeviceWaitIdle(d->device); vkDestroyFence(d->device, fence, NULL); }
    if (cmd) vkFreeCommandBuffers(d->device, d->command_pool, 1, &cmd);
    s2a_gpu_buf_destroy(d, &shared);
    s2a_gpu_buf_destroy(d, &dst);
    if (guest_map != MAP_FAILED) munmap(guest_map, size);
    else if (reserved != MAP_FAILED) munmap(reserved, size);
    if (fd >= 0) close(fd);
    AHardwareBuffer_release(ahb);
    if (why && why_size) snprintf(why, why_size, "%s", text);
    return rc;
}

// 取 AHB 的 dma-buf fd（公开 API：sendHandleToUnixSocket + recvmsg 取 SCM_RIGHTS）。
// 用来把共享页映射到指定地址，以及做范围 cache 维护。
int s2a_ahb_fd_acquire(void *ahb_ptr, int *out_fd, int64_t *out_off, char *why, size_t why_size) {
#if defined(__ANDROID__)
    AHardwareBuffer *ahb = (AHardwareBuffer *)ahb_ptr;
    int sv[2] = { -1, -1 };
    if (!ahb || !out_fd) return fail(why, why_size, "fd: bad arguments");
    if (socketpair(AF_UNIX, SOCK_SEQPACKET, 0, sv) != 0) return fail(why, why_size, "fd: socketpair failed");
    int rc = -1;
    char text[160] = "";
    if (AHardwareBuffer_sendHandleToUnixSocket(ahb, sv[0]) != 0) {
        snprintf(text, sizeof text, "fd: sendHandleToUnixSocket errno=%d", errno);
        goto done;
    }
    {
        char buf[512];
        char cbuf[CMSG_SPACE(4 * sizeof(int))];
        struct iovec iov = { buf, sizeof buf };
        struct msghdr msg = {0};
        msg.msg_iov = &iov; msg.msg_iovlen = 1;
        msg.msg_control = cbuf; msg.msg_controllen = sizeof cbuf;
        ssize_t n = recvmsg(sv[1], &msg, 0);
        if (n < 0) { snprintf(text, sizeof text, "fd: recvmsg errno=%d", errno); goto done; }
        int fd = -1;
        for (struct cmsghdr *c = CMSG_FIRSTHDR(&msg); c; c = CMSG_NXTHDR(&msg, c))
            if (c->cmsg_level == SOL_SOCKET && c->cmsg_type == SCM_RIGHTS)
                memcpy(&fd, CMSG_DATA(c), sizeof fd);
        if (fd < 0) { snprintf(text, sizeof text, "fd: no SCM_RIGHTS fd"); goto done; }
        int64_t off = 0;
        if (n >= 3 * (ssize_t)sizeof(int32_t)) {
            int32_t *h = (int32_t *)buf;
            int num_fds = h[1], num_ints = h[2];
            if (num_ints > 0 && n >= (3 + num_fds + 1) * (ssize_t)sizeof(int32_t))
                off = h[3 + num_fds];
        }
        *out_fd = fd;
        if (out_off) *out_off = off;
        rc = 0;
    }
done:
    if (sv[0] >= 0) close(sv[0]);
    if (sv[1] >= 0) close(sv[1]);
    if (rc != 0) fail(why, why_size, text);
    return rc;
#else
    (void)ahb_ptr; (void)out_fd; (void)out_off;
    return fail(why, why_size, "fd: not built for this platform");
#endif
}

int s2a_gpu_buf_map_at(struct s2a_gpu_buf *b, void *addr, size_t len, void **mapped,
                       char *why, size_t why_size) {
    if (!b || !addr || !len || !mapped) return fail(why, why_size, "map_at: bad arguments");
#if defined(__ANDROID__)
    if (b->kind != S2A_GPU_MEM_AHB || !b->ahb)
        return fail(why, why_size, "map_at: only AHB buffers support alias mapping");
    char t[160] = "";
    if (b->fd <= 0) {
        int64_t off = 0;
        if (s2a_ahb_fd_acquire(b->ahb, &b->fd, &off, t, sizeof t) != 0)
            return fail(why, why_size, t);
        b->fd_off = off;   // 记下 gralloc 偏移，后面 mmap 与 cache 维护共用
    }
    // 必须用 AHB 的 gralloc 偏移映射（旧实现写死 0，与 ahb_alias_probe 用偏移的口径不一致）；
    // mmap 要求文件偏移页对齐，非页对齐时无法在该地址精确映射——明确拒绝，不猜。
    long pg = sysconf(_SC_PAGESIZE);
    if (pg <= 0) pg = 4096;
    if (b->fd_off < 0 || (b->fd_off % (int64_t)pg) != 0) {
        char e[160];
        snprintf(e, sizeof e, "map_at: AHB offset %lld not page aligned", (long long)b->fd_off);
        return fail(why, why_size, e);
    }
    void *m = mmap(addr, len, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_FIXED, b->fd, (off_t)b->fd_off);
    if (m == MAP_FAILED || m != addr) {
        char e[160];
        snprintf(e, sizeof e, "map_at: MAP_FIXED failed addr=%p got=%p errno=%d", addr, m, errno);
        if (m != MAP_FAILED) munmap(m, len);
        return fail(why, why_size, e);
    }
    *mapped = m;
    return 0;
#else
    (void)b; (void)addr; (void)len; (void)mapped;
    return fail(why, why_size, "map_at: not built for this platform");
#endif
}

void s2a_gpu_buf_sync_to_gpu(struct s2a_vk_device *device, struct s2a_gpu_buf *b,
                             VkDeviceSize off, VkDeviceSize len) {
    if (!device || !b || !len) return;
#if defined(__ANDROID__)
    if (b->kind == S2A_GPU_MEM_AHB) {
        if (b->fd <= 0 || b->coherent) return;
        // dma-buf 的 cache 维护：DMA_BUF_IOCTL_SYNC(END|WRITE) 把这段 CPU 写过的字节清到内存。
        // NDK 没有 linux/dma-buf.h，这里按内核 ABI 定义（结构体只含 flags，命令号 _IOW('b', 0, struct)）。
        struct s2a_dma_buf_sync { uint64_t flags; };
        enum { S2A_DMA_BUF_SYNC_READ = 1, S2A_DMA_BUF_SYNC_WRITE = 2, S2A_DMA_BUF_SYNC_END = 4 };
        struct s2a_dma_buf_sync arg;
        arg.flags = S2A_DMA_BUF_SYNC_END | S2A_DMA_BUF_SYNC_WRITE;
        unsigned long cmd = (1u << 30) | ((unsigned long)sizeof arg << 16) | ('b' << 8) | 0;   // _IOW('b',0,..)
        (void)off;   // 内核 ABI 的 ioctl 只带 flags，范围由驱动整块处理
        (void)len;
        if (ioctl(b->fd, cmd, &arg) == 0) return;
        // ioctl 不支持时退回“整块 unlock/lock”提交（有 fence 语义，代价更高但正确）。
        if (b->ahb) ahb_flush_relock((struct s2a_gpu_buf *)b);
        return;
    }
#endif
    s2a_gpu_buf_flush(device, b, off, len);
}

// 散写基准：guest 生成顶点时是**小粒度随机写**，与顺序 memcpy 完全不同。
// 不可缓存/写合并的映射上，顺序写能跑到 GB/s，但 4 字节散写会退化几个数量级——
// 这决定“能不能把 guest 池直接放在 AHB 上”。返回平均每次写的纳秒数（越小越好），失败 <0。
double s2a_gpu_mem_bench_scatter(struct s2a_vk_device *device, int kind, size_t bytes,
                                char *why, size_t why_size) {
    struct s2a_gpu_buf b = {0};
    void *host_mem = NULL;
    char inner[192] = "";
    const VkBufferUsageFlags scatter_usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT |
                                             VK_BUFFER_USAGE_VERTEX_BUFFER_BIT | VK_BUFFER_USAGE_INDEX_BUFFER_BIT |
                                             VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT;
    int created;
    if (kind == S2A_GPU_MEM_HOST_IMPORT) {
        // 导入路径没有“创建”：自己准备对齐的 host 内存再导入（以前这里恒失败）。
        VkDeviceSize align = device->host_pointer_alignment ? device->host_pointer_alignment : 4096;
        if (align < (VkDeviceSize)sizeof(void *)) align = (VkDeviceSize)sizeof(void *);
        if (posix_memalign(&host_mem, (size_t)align, bytes) != 0 || !host_mem) {
            host_mem = NULL;
            created = -1;
            snprintf(inner, sizeof inner, "scatter: host allocation for import failed");
        } else {
            created = s2a_gpu_buf_import(device, host_mem, (VkDeviceSize)bytes, scatter_usage, &b, inner, sizeof inner);
        }
    } else {
        created = s2a_gpu_buf_create(device, (VkDeviceSize)bytes, scatter_usage, kind, &b, inner, sizeof inner);
    }
    if (created) {
        free(host_mem);
        if (why && why_size) snprintf(why, why_size, "scatter create failed: %s", inner);
        return -1.0;
    }
    if (!b.cpu) { s2a_gpu_buf_destroy(device, &b); free(host_mem); return -1.0; }
    volatile uint32_t *p = (volatile uint32_t *)b.cpu;
    const size_t words = bytes / 4;
    const size_t stride = 16;   // 每 64 字节写一次，模拟交错/分量写
    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    size_t ops = 0;
    for (size_t i = 0; i < words; i += stride) { p[i] = (uint32_t)i; ops++; }
    clock_gettime(CLOCK_MONOTONIC, &t1);
    double ns = (double)(t1.tv_sec - t0.tv_sec) * 1e9 + (double)(t1.tv_nsec - t0.tv_nsec);
    s2a_gpu_buf_destroy(device, &b);
    free(host_mem);
    if (why && why_size) snprintf(why, why_size, "kind=%d ops=%zu", kind, ops);
    return ops ? ns / (double)ops : -1.0;
}

// 只有 AHB 路径需要验证“guest 地址 ↔ GPU 同一块页”。
int s2a_gpu_mem_selftest_alias(struct s2a_vk_device *device, char *why, size_t why_size) {
    if (!device || !device->device) return fail(why, why_size, "no device");
    if (!device->ahb_import_enabled) return fail(why, why_size, "alias: ahb import not enabled");
    return ahb_alias_probe(device, why, why_size);
}
#else
int s2a_gpu_mem_selftest_alias(struct s2a_vk_device *device, char *why, size_t why_size) {
    (void)device;
    return fail(why, why_size, "alias: not built for this platform");
}
#endif
