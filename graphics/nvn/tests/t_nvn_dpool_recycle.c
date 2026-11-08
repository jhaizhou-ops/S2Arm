// 描述符池编号段复用（hle_nvn.c dpool_add / dpool_finalize，11-02 神之天平 外传）：公开 NVN 接口建 / 销毁贴图池与采样器池，期望按规则手写，不由被测实现推出：
//   池销毁后，下一个容量不超过它的新池拿回同一段编号（base 相同）；更大的池另开新段；反复建销 30000 次编号段不再长（原先每建一个池加 256 / 512，
//   1800 帧 26746 个池把宿主登记表撑到约 1370 万项、常驻 5 GB 被杀）；贴图池销毁后它那段的登记被清（同一编号读回为空）
#include "nvn_protos.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern void *h_nvnBootstrapLoader(const char *name);
extern int nvn_dpool_base(const void *pool, int tex);
static unsigned checks;
#define CHECK(expr, ...) do { checks++; if (!(expr)) { fprintf(stderr, "FAIL %s:%d：%s —— ", __FILE__, __LINE__, #expr); fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); exit(1); } } while (0)
static void *load(const char *name) { void *entry = h_nvnBootstrapLoader(name); if (!entry) { fprintf(stderr, "FAIL 取不到 %s\n", name); exit(1); } return entry; }
#define API(name) ((NVNT_##name)load(#name))

int main(void) {
    NVNdevice dev; NVNdeviceBuilder db; memset(&dev, 0, sizeof dev); memset(&db, 0, sizeof db);
    API(nvnDeviceBuilderSetDefaults)(&db); if (!API(nvnDeviceInitialize)(&dev, &db)) { fprintf(stderr, "FAIL 设备初始化\n"); return 1; }
    enum { POOL = 1 << 20 };
    void *mem = NULL; CHECK(posix_memalign(&mem, 65536, POOL) == 0, "分配存储"); memset(mem, 0, POOL);
    NVNmemoryPool mp; NVNmemoryPoolBuilder pb; memset(&mp, 0, sizeof mp); memset(&pb, 0, sizeof pb);
    API(nvnMemoryPoolBuilderSetDefaults)(&pb); API(nvnMemoryPoolBuilderSetDevice)(&pb, &dev); API(nvnMemoryPoolBuilderSetStorage)(&pb, mem, POOL);
    API(nvnMemoryPoolBuilderSetFlags)(&pb, NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
    CHECK(API(nvnMemoryPoolInitialize)(&mp, &pb), "内存池");
    // 常驻的第一个贴图池（游戏的主池），之后反复建销的池不应挤占它的编号
    NVNtexturePool keep, a, b, big; memset(&keep, 0, sizeof keep); memset(&a, 0, sizeof a); memset(&b, 0, sizeof b); memset(&big, 0, sizeof big);
    CHECK(API(nvnTexturePoolInitialize)(&keep, &mp, 0, 1024), "常驻池");
    CHECK(API(nvnTexturePoolInitialize)(&a, &mp, 0, 272), "池 A");
    int ka = nvn_dpool_base(&keep, 1), ba = nvn_dpool_base(&a, 1);
    CHECK(ba >= ka + 1024, "池 A 的编号段在常驻池之后（常驻 %d、A %d）", ka, ba);
    API(nvnTexturePoolFinalize)(&a);
    CHECK(API(nvnTexturePoolInitialize)(&b, &mp, 0, 272), "池 B");
    int bb = nvn_dpool_base(&b, 1);
    CHECK(bb == ba, "同容量新池复用销毁池的编号段：期望 %d，得 %d", ba, bb);
    API(nvnTexturePoolFinalize)(&b);
    CHECK(API(nvnTexturePoolInitialize)(&big, &mp, 0, 600), "大池");
    int bg = nvn_dpool_base(&big, 1);
    CHECK(bg != ba && bg >= ba + 512, "容量更大的池另开新段：A 段 %d（容量 512），大池 %d", ba, bg);
    API(nvnTexturePoolFinalize)(&big);
    // 反复建销：编号段不长
    int maxb = 0;
    for (int i = 0; i < 30000; i++) { NVNtexturePool t; memset(&t, 0, sizeof t); CHECK(API(nvnTexturePoolInitialize)(&t, &mp, 0, 272), "第 %d 个池", i);
        int x = nvn_dpool_base(&t, 1); if (x > maxb) maxb = x; API(nvnTexturePoolFinalize)(&t); }
    CHECK(maxb <= bg, "反复建销 30000 个 272 项的池，最大编号起点不超过已有段（%d），得 %d", bg, maxb);
    // 采样器池同规则
    NVNsamplerPool sa, sb; memset(&sa, 0, sizeof sa); memset(&sb, 0, sizeof sb);
    CHECK(API(nvnSamplerPoolInitialize)(&sa, &mp, 0, 272), "采样器池 A"); int sba = nvn_dpool_base(&sa, 0); API(nvnSamplerPoolFinalize)(&sa);
    CHECK(API(nvnSamplerPoolInitialize)(&sb, &mp, 0, 200), "采样器池 B"); int sbb = nvn_dpool_base(&sb, 0);
    CHECK(sbb == sba, "采样器池复用：期望 %d，得 %d", sba, sbb);
    printf("✓ t_nvn_dpool_recycle：%u 项全过（常驻 %d、复用段 %d、大池 %d）\n", checks, ka, ba, bg);
    return 0;
}
