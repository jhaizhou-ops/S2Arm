// GPU 内存层：绘制层只拿 VkBuffer + offset（BufferRef），「这段内存是怎么来的」由这一层统一决定。
//
// 为什么要独立一层：Metal 侧一条 newBufferWithBytesNoCopy 就能把 guest 内存直接当缓冲用（零拷贝），
// Vulkan 没有等价能力，只能按设备实际支持的后端挑一条路：
//   1) S2A_GPU_MEM_HOST_IMPORT  VK_EXT_external_memory_host：把 host 指针（guest 池直映射地址）导入成缓冲，零拷贝；
//   2) S2A_GPU_MEM_AHB          VK_ANDROID_external_memory_android_hardware_buffer：分配 AHardwareBuffer 当后备页，
//                              guest 与 Vulkan 共用同一块页（CPU 侧经 AHardwareBuffer_lock 映射）；
//   3) S2A_GPU_MEM_DMABUF       VK_EXT_external_memory_dma_buf / VK_KHR_external_memory_fd：共用 dma-buf 后备页；
//   4) S2A_GPU_MEM_UPLOAD       以上都不可用：保留正确的上传路径（host-visible arena，按内容变化减少重复拷贝）。
//
// 分配、导入、cache 维护、fence 后释放都在这一层完成；cache 维护按**实测内存属性**决定
// （HOST_COHERENT 直接免维护，非一致才 flush/invalidate），不按厂商名分支。
#pragma once
#include <stddef.h>
#include <stdint.h>
#include <vulkan/vulkan.h>

#ifdef __cplusplus
extern "C" {
#endif

struct s2a_vk_device;

enum s2a_gpu_mem_kind {
    S2A_GPU_MEM_NONE = 0,
    S2A_GPU_MEM_UPLOAD,        // CPU 写进 host-visible arena，再绑定给 GPU（当前默认）
    S2A_GPU_MEM_HOST_IMPORT,   // 导入已有 host 指针（零拷贝）
    S2A_GPU_MEM_AHB,           // AHardwareBuffer 共享后备页
    S2A_GPU_MEM_DMABUF,        // dma-buf 共享后备页
};

struct s2a_gpu_mem_caps {
    int host_import;            // 驱动 advertise 且导入自检通过
    VkDeviceSize host_align;    // minImportedHostPointerAlignment
    int ahb;                    // 驱动 advertise 且自检通过
    int dmabuf;                 // 驱动 advertise（本层不负责分配 dma-buf）
    int shared_enabled;         // debug.s2a.mem_shared=1 时要求走共享后端
    int chosen;                 // 新分配的共享缓冲实际采用的后端（枚举 s2a_gpu_mem_kind）
};

// 一个可交给绘制层的缓冲：上层只用 buf/offset/size。
struct s2a_gpu_buf {
    VkBuffer buf;
    VkDeviceMemory mem;
    VkDeviceSize size;
    VkDeviceSize alloc_size;
    int kind;          // s2a_gpu_mem_kind
    int coherent;      // 由实际内存属性决定：1 = 不需要 flush/invalidate
    int mapped;        // cpu 是否可写
    void *cpu;         // CPU 映射（导入/共享后端为共享页；上传后端也映射，便于 memcpy）
    void *ahb;         // AHardwareBuffer*（kind == AHB 时持有，销毁时释放）
    int fd;            // AHB 的 dma-buf fd（用于把共享页映射到指定地址 + 范围 cache 维护）
    int64_t fd_off;    // 该 fd 对应的 gralloc 偏移（从 AHB native handle 取，map_at 必须用它，不能写死 0）
};

// 探测能力并（在要求时）为设备启用共享后端扩展。不改任何绘制行为；结果写进 caps。
int s2a_gpu_mem_probe(struct s2a_vk_device *device, struct s2a_gpu_mem_caps *caps,
                      char *why, size_t why_size);
const struct s2a_gpu_mem_caps *s2a_gpu_mem_caps_get(void);

// 后端自检：按 kind 建一个 CPU 可写缓冲，CPU 写图案 → GPU 拷贝到普通缓冲 → CPU 读回比对。
// 这是「这条共享路径在这台设备上真的可用」的唯一判据（扩展存在 != 能用）。
int s2a_gpu_mem_selftest(struct s2a_vk_device *device, int kind, char *why, size_t why_size);

// 新建一段可 CPU 写、GPU 读的缓冲。kind 传 S2A_GPU_MEM_NONE 表示按能力自动选。
int s2a_gpu_buf_create(struct s2a_vk_device *device, VkDeviceSize size, VkBufferUsageFlags usage,
                       int kind, struct s2a_gpu_buf *out, char *why, size_t why_size);
// 导入一段已存在的 host 指针（guest 池直映射地址）成缓冲；只有 HOST_IMPORT 后端支持。
int s2a_gpu_buf_import(struct s2a_vk_device *device, const void *host, VkDeviceSize size,
                       VkBufferUsageFlags usage, struct s2a_gpu_buf *out, char *why, size_t why_size);
// cache 维护：按 b->coherent 决定是否真的调用（一致性内存直接返回）。
void s2a_gpu_buf_flush(struct s2a_vk_device *device, const struct s2a_gpu_buf *b,
                       VkDeviceSize off, VkDeviceSize len);
void s2a_gpu_buf_invalidate(struct s2a_vk_device *device, const struct s2a_gpu_buf *b,
                            VkDeviceSize off, VkDeviceSize len);
void s2a_gpu_buf_destroy(struct s2a_vk_device *device, struct s2a_gpu_buf *b);
// 把共享缓冲的后备页映射到**指定地址**（MAP_FIXED 覆盖）：guest 地址与 GPU 共用同一块页的机制。
// 前提是该地址范围已由调用者预留/拥有；成功返回 0，映射地址写进 *mapped。
int s2a_gpu_buf_map_at(struct s2a_gpu_buf *b, void *addr, size_t len, void **mapped,
                       char *why, size_t why_size);
// 范围 cache 维护：把 CPU 写过的 [off, off+len) 清到内存，保证 GPU 读到最新内容。
// 按后端实际机制决定（AHB 走 dma-buf ioctl；host-visible 走 vkFlushMappedMemoryRanges；一致性内存直接跳过）。
void s2a_gpu_buf_sync_to_gpu(struct s2a_vk_device *device, struct s2a_gpu_buf *b,
                             VkDeviceSize off, VkDeviceSize len);
// 带宽基准（诊断）：这条后端当 guest 可写内存用时 CPU 写入 MB/s；失败返回负数并写 why。
double s2a_gpu_mem_bench(struct s2a_vk_device *device, int kind, size_t bytes,
                         char *why, size_t why_size);
// 散写基准（纳秒/次）：guest 生成顶点是小粒度随机写，决定“guest 池能否直接放在 AHB 上”。
double s2a_gpu_mem_bench_scatter(struct s2a_vk_device *device, int kind, size_t bytes,
                                 char *why, size_t why_size);
// AHB 别名自检：同一块 AHB 后备页能否既映射进 guest 地址、又被 Vulkan 使用（零拷贝前提）。
int s2a_gpu_mem_selftest_alias(struct s2a_vk_device *device, char *why, size_t why_size);

#ifdef __cplusplus
}
#endif
