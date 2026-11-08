// 池的 GPU 地址（hle_nvn.c「GPU 地址空间」）：公开 NVN 接口 → 真实 Metal 提交 → 读回 CPU 存储。期望值按 Switch 语义手写，不由被测实现推出：
//   真机驱动按 64 KB 大页把池映射进 GPU 地址空间，缓冲区地址 64 KB 对齐，与存储的 CPU 地址无关（通用模式真驱动给十三机兵的池 0x2ba8b0000，存储 CPU 0x71175bb000）；
//   GPU 命令按缓冲区地址 + 偏移读写，落在存储同一偏移；nvnBufferGetAddress = 池缓冲区地址 + 缓冲偏移；同时活着的两个池地址区间不相交。
// 存储故意放在 4 KB 对齐、非 64 KB 对齐处（旧实现直接把 CPU 指针当缓冲区地址，对齐那条红）。
#include "nvn_protos.h"
#import <Foundation/Foundation.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern void *h_nvnBootstrapLoader(const char *name);
extern int mtl_last_commit_error(void);
static NVNdevice device;
static NVNqueue queue;
static NVNcommandBuffer commands;
static unsigned checks;
static const char *phase = "初始化";
enum { POOL_SIZE = 4 << 20, COMMAND_SIZE = 1 << 20, SRC = 2 << 20, DST = 3 << 20, N = 4096, SKEW = 0x5000 };
#define REQUIRE(x) do { checks++; if (!(x)) { printf("✗ t_nvn_gva：[%s] %s:%d: %s\n", phase, __FILE__, __LINE__, #x); exit(1); } } while (0)
static void *load(const char *name) { void *entry = h_nvnBootstrapLoader(name); REQUIRE(entry != NULL); return entry; }
#define API(name) ((NVNT_##name)load(#name))
typedef struct { NVNmemoryPool pool; uint8_t *mem; } pool_box;
static void make_pool(pool_box *b) {
    void *raw; REQUIRE(posix_memalign(&raw, 65536, POOL_SIZE + 65536) == 0);
    b->mem = (uint8_t *)raw + SKEW; memset(b->mem, 0, POOL_SIZE);   // 4 KB 对齐、非 64 KB 对齐
    NVNmemoryPoolBuilder pb; API(nvnMemoryPoolBuilderSetDefaults)(&pb); API(nvnMemoryPoolBuilderSetDevice)(&pb, &device);
    API(nvnMemoryPoolBuilderSetStorage)(&pb, b->mem, POOL_SIZE);
    API(nvnMemoryPoolBuilderSetFlags)(&pb, NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
    REQUIRE(API(nvnMemoryPoolInitialize)(&b->pool, &pb));
}
static void copy_check(pool_box *cmd, pool_box *b, const char *what) {
    phase = what;
    for (int i = 0; i < N; i++) b->mem[SRC + i] = (uint8_t)(i * 7 + 3);
    memset(b->mem + DST, 0xA5, N);
    NVNbufferAddress ba = API(nvnMemoryPoolGetBufferAddress)(&b->pool);
    REQUIRE(ba % 65536 == 0);
    API(nvnCommandBufferAddCommandMemory)(&commands, &cmd->pool, 0, COMMAND_SIZE); API(nvnCommandBufferBeginRecording)(&commands);
    API(nvnCommandBufferCopyBufferToBuffer)(&commands, ba + SRC, ba + DST, N, 0);
    NVNcommandHandle h = API(nvnCommandBufferEndRecording)(&commands); REQUIRE(h != 0);
    API(nvnQueueSubmitCommands)(&queue, 1, &h); API(nvnQueueFinish)(&queue); REQUIRE(mtl_last_commit_error() == 0);
    REQUIRE(memcmp(b->mem + DST, b->mem + SRC, N) == 0);
}
int main(void) {
    @autoreleasepool {
        NVNdeviceBuilder db; API(nvnDeviceBuilderSetDefaults)(&db); REQUIRE(API(nvnDeviceInitialize)(&device, &db));
        NVNqueueBuilder qb; API(nvnQueueBuilderSetDefaults)(&qb); API(nvnQueueBuilderSetDevice)(&qb, &device);
        REQUIRE(API(nvnQueueInitialize)(&queue, &qb)); REQUIRE(API(nvnCommandBufferInitialize)(&commands, &device));
        static uint8_t control[16384]; API(nvnCommandBufferAddControlMemory)(&commands, control, sizeof control);
        static pool_box a, b, c;
        make_pool(&a); make_pool(&b);
        copy_check(&a, &a, "池 A：缓冲区地址 64 KB 对齐，GPU 拷贝落在存储同一偏移");
        copy_check(&a, &b, "池 B：同上（命令内存在池 A）");
        phase = "两池地址区间不相交";
        NVNbufferAddress pa = API(nvnMemoryPoolGetBufferAddress)(&a.pool), pb = API(nvnMemoryPoolGetBufferAddress)(&b.pool);
        REQUIRE(pa + POOL_SIZE <= pb || pb + POOL_SIZE <= pa);
        phase = "nvnBufferGetAddress = 池缓冲区地址 + 偏移";
        NVNbufferBuilder bb; API(nvnBufferBuilderSetDefaults)(&bb); API(nvnBufferBuilderSetDevice)(&bb, &device);
        API(nvnBufferBuilderSetStorage)(&bb, &b.pool, SRC, N); NVNbuffer buf; REQUIRE(API(nvnBufferInitialize)(&buf, &bb));
        REQUIRE(API(nvnBufferGetAddress)(&buf) == pb + SRC);
        API(nvnBufferFinalize)(&buf);
        API(nvnMemoryPoolFinalize)(&b.pool); make_pool(&c);
        copy_check(&a, &c, "池 B 释放后新建池 C：照常");
        printf("✓ t_nvn_gva：全部通过（%u 项检查）\n", checks);
    }
    return 0;
}
