// CPU 不可访问的池映射给 NULL（hle_nvn.c nvnMemoryPoolMap / nvnBufferMap，11-02 FC 26）：公开 NVN 接口、真实池与缓冲对象。期望按 NVN 语义手写，不由被测实现推出：
//   池标志带 CPU_NO_ACCESS（0x1）→ 两个 Map 都是 NULL；CPU 可访问（CPU_CACHED / CPU_UNCACHED）→ 池 Map = 存储指针，缓冲 Map = 存储 + 偏移。
//   FC 26 引擎的算式「拷贝源 = 缓冲 GPU 地址 + (CPU 指针 − nvnBufferMap)」在 CPU 不可访问的池上把 CPU 指针记 0，算回 GPU 地址的前提就是 Map 也给 NULL（反证一并核：GPU 地址照常给出、与存储无关）
#include "nvn_protos.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern void *h_nvnBootstrapLoader(const char *name);
static unsigned checks;
#define CHECK(expr, ...) do { checks++; if (!(expr)) { fprintf(stderr, "FAIL %s:%d：%s —— ", __FILE__, __LINE__, #expr); fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); exit(1); } } while (0)
static void *load(const char *name) { void *entry = h_nvnBootstrapLoader(name); if (!entry) { fprintf(stderr, "FAIL 取不到 %s\n", name); exit(1); } return entry; }
#define API(name) ((NVNT_##name)load(#name))
enum { POOL = 1 << 20, OFF = 0x10000, LEN = 4096 };

static void one(NVNdevice *dev, int flags, int none, const char *what) {
    void *mem = NULL; CHECK(posix_memalign(&mem, 65536, POOL) == 0, "分配存储"); memset(mem, 0, POOL);
    NVNmemoryPool pool; NVNmemoryPoolBuilder pb; memset(&pool, 0, sizeof pool); memset(&pb, 0, sizeof pb);
    API(nvnMemoryPoolBuilderSetDefaults)(&pb); API(nvnMemoryPoolBuilderSetDevice)(&pb, dev);
    API(nvnMemoryPoolBuilderSetStorage)(&pb, mem, POOL); API(nvnMemoryPoolBuilderSetFlags)(&pb, flags);
    CHECK(API(nvnMemoryPoolInitialize)(&pool, &pb), "%s：池初始化", what);
    NVNbuffer buf; NVNbufferBuilder bb; memset(&buf, 0, sizeof buf); memset(&bb, 0, sizeof bb);
    API(nvnBufferBuilderSetDefaults)(&bb); API(nvnBufferBuilderSetDevice)(&bb, dev); API(nvnBufferBuilderSetStorage)(&bb, &pool, OFF, LEN);
    CHECK(API(nvnBufferInitialize)(&buf, &bb), "%s：缓冲初始化", what);
    void *pm = API(nvnMemoryPoolMap)(&pool), *bm = API(nvnBufferMap)(&buf);
    NVNbufferAddress pa = API(nvnMemoryPoolGetBufferAddress)(&pool), ba = API(nvnBufferGetAddress)(&buf);
    if (none) { CHECK(pm == NULL, "%s：池 Map 应 NULL，得 %p", what, pm); CHECK(bm == NULL, "%s：缓冲 Map 应 NULL，得 %p", what, bm); }
    else { CHECK(pm == mem, "%s：池 Map 应 %p，得 %p", what, mem, pm); CHECK(bm == (uint8_t *)mem + OFF, "%s：缓冲 Map 应 %p，得 %p", what, (void *)((uint8_t *)mem + OFF), bm); }
    CHECK(pa != 0 && ba == pa + OFF, "%s：GPU 地址照常给出（池 %#llx、缓冲 %#llx，应池 + %#x）", what, (unsigned long long)pa, (unsigned long long)ba, OFF);
    // FC 26 的算式：GPU 地址 + (引擎记的 CPU 指针 − BufferMap)；CPU 不可访问时引擎记 0。结果须等于缓冲 GPU 地址
    uint64_t engine_cpu = none ? 0 : (uint64_t)(uintptr_t)bm, src = (uint64_t)ba + (engine_cpu - (uint64_t)(uintptr_t)bm);
    CHECK(src == (uint64_t)ba, "%s：引擎算式得 %#llx，应等于缓冲 GPU 地址 %#llx", what, (unsigned long long)src, (unsigned long long)ba);
    API(nvnBufferFinalize)(&buf); API(nvnMemoryPoolFinalize)(&pool); free(mem);
    printf("✓ %s\n", what);
}
int main(void) {
    NVNdevice dev; NVNdeviceBuilder db; memset(&dev, 0, sizeof dev); memset(&db, 0, sizeof db);
    API(nvnDeviceBuilderSetDefaults)(&db); if (!API(nvnDeviceInitialize)(&dev, &db)) { fprintf(stderr, "FAIL 设备初始化\n"); return 1; }
    one(&dev, NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS | NVN_MEMORY_POOL_FLAGS_GPU_CACHED, 1, "CPU 不可访问（0x21，同建池缺省）：两个 Map 都是 NULL");
    one(&dev, NVN_MEMORY_POOL_FLAGS_CPU_CACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED, 0, "CPU 带缓存（0x24）：池 Map = 存储、缓冲 Map = 存储 + 偏移");
    one(&dev, NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED, 0, "CPU 不经缓存（0x22）：同上");
    printf("✓ t_nvn_map_noaccess：%u 项全过\n", checks);
    return 0;
}
