// 满屏按内容判横向细节不直接读虚拟池贴图的内存（widen_glue.inc wd_flat_want；11-05 旷野之息 Windows 出包、测试机2 开局动画后闪退 3/3：
//   SIGBUS 地址落在虚拟池自己的地址段里 0x126c00000+0x7300000，pc wd_draw_ 里内联的 full_hash）。
//   虚拟池（NVN_MEMORY_POOL_FLAGS_VIRTUAL）的贴图只能按页表读（hle_nvn.c nvn_sparse_copy）：池自己的地址段只有对齐到主机页的映射才真挂上，没挂的页一读就 SIGBUS /
//   SIGSEGV。渲染器自己的整张哈希一向跳过（nvn_mtl.m pk->sparse），量测这处漏了。
// 造法：虚拟池一页都不映射（地址段全空），在上面建一张 256×128 RGBA8 随包贴图，tex_mtl 先传一次（按页表读，未映射读成 0），再调 wd_flat_want。
// 期望（手写）：① 不崩（旧实现在 full_hash 里读未映射地址，进程收信号退出 = 红）；② 这张不进磁盘缓存（内容哈希 0，g_wd_flat_hits 不变）。
#include "../gfx/nvn/nvn_mtl.m"
#include "nvn_protos.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
extern void *h_nvnBootstrapLoader(const char *name);
static NVNdevice device; static NVNqueue queue;
static unsigned checks, fails;
#define REQUIRE(x) do { checks++; if (!(x)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #x); exit(1); } } while (0)
static void *load(const char *name) { void *entry = h_nvnBootstrapLoader(name); REQUIRE(entry != NULL); return entry; }
#define API(name) ((NVNT_##name)load(#name))
enum { W = 256, H = 128, VSIZE = 4 << 20 };
int main(void) {
    @autoreleasepool {
        setenv("S2A_WIDEN_FLAT_CACHE", "/dev/null", 1);   // 不读本机磁盘缓存
        NVNdeviceBuilder db; API(nvnDeviceBuilderSetDefaults)(&db); REQUIRE(API(nvnDeviceInitialize)(&device, &db));
        NVNqueueBuilder qb; API(nvnQueueBuilderSetDefaults)(&qb); API(nvnQueueBuilderSetDevice)(&qb, &device);
        REQUIRE(API(nvnQueueInitialize)(&queue, &qb)); mtl_init();
        NVNmemoryPool v; memset(&v, 0, sizeof v);
        NVNmemoryPoolBuilder pb; API(nvnMemoryPoolBuilderSetDefaults)(&pb); API(nvnMemoryPoolBuilderSetDevice)(&pb, &device);
        API(nvnMemoryPoolBuilderSetStorage)(&pb, NULL, VSIZE);
        API(nvnMemoryPoolBuilderSetFlags)(&pb, NVN_MEMORY_POOL_FLAGS_VIRTUAL | NVN_MEMORY_POOL_FLAGS_GPU_CACHED | NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS);
        REQUIRE(API(nvnMemoryPoolInitialize)(&v, &pb));
        NVNtexture t; NVNtextureBuilder b; API(nvnTextureBuilderSetDefaults)(&b); API(nvnTextureBuilderSetDevice)(&b, &device);
        API(nvnTextureBuilderSetTarget)(&b, NVN_TEXTURE_TARGET_2D); API(nvnTextureBuilderSetSize2D)(&b, W, H); API(nvnTextureBuilderSetLevels)(&b, 1);
        API(nvnTextureBuilderSetFormat)(&b, NVN_FORMAT_RGBA8); API(nvnTextureBuilderSetStorage)(&b, &v, 0); REQUIRE(API(nvnTextureInitialize)(&t, &b));
        const tex_t *tt = (const tex_t *)&t;
        REQUIRE(tt->pool && nvn_sparse_pool(tt->pool));   // 前提：确实是虚拟池贴图
        REQUIRE(tex_mtl(tt) != nil);                       // 先按页表传一次（建出随包记录 NvPkg）
        REQUIRE([tex_get(tt->serial) isKindOfClass:[NvPkg class]]);
        uint64_t hits0 = g_wd_flat_hits;
        pthread_mutex_lock(&g_wd_mu); wd_flat_want(tt); pthread_mutex_unlock(&g_wd_mu);   // 旧实现：在这里读虚拟池未映射的地址段，进程收信号
        checks++; printf("✓ ① 虚拟池贴图量测不崩\n");
        checks++; if (g_wd_flat_hits != hits0) { fails++; printf("✗ ② 磁盘缓存命中数变了（%llu → %llu）\n", (unsigned long long)hits0, (unsigned long long)g_wd_flat_hits); }
        else printf("✓ ② 不按内容哈希查磁盘缓存\n");
        uint64_t ser = tt->serial; pthread_mutex_lock(&g_wd_flat_mu); uintptr_t st = (uintptr_t)nvn_hm_get(&g_wd_flat, &ser); pthread_mutex_unlock(&g_wd_flat_mu);
        checks++; if (!st) { fails++; printf("✗ ③ 量测表里没有这张（应记成待量或有细节）\n"); } else printf("✓ ③ 照常进量测表（状态 %#lx）\n", (unsigned long)st);
    }
    if (fails) { printf("t_nvn_wdflat_sparse：%u 项里 %u 项不过\n", checks, fails); return 1; }
    printf("✓ t_nvn_wdflat_sparse：3 项断言 + %u 项前提（虚拟池贴图量测不读未映射内存）\n", checks - 3); return 0;
}
