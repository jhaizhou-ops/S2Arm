// 我方内存按种类（nvn_mtl.m nvn_be_mem_kinds；S2A_MEM_SPLIT 的 100 ms 跳变行用，ios/app.m）。
// 背景：11-05 时之笛 Switch 2 第二十二版读档局，约 4 秒实占涨 3.5 GB 到 8192 MB 被杀，10 秒心跳看不到构成；跳变行要把我方拆成私有贴图 / 私有缓冲 / 游戏池零拷贝缓冲 / 其它共享缓冲。
// 期望（不跑被测实现就能定：每项增量 = 本测新建对象自己报的 allocatedSize / length）：
//   建 1024x1024 RGBA8 私有贴图 → 私有贴图 +它的 allocatedSize；2 MB 私有缓冲 → 私有缓冲 +allocatedSize；1 MB 共享缓冲 → 其它共享缓冲 +allocatedSize；
//   两个 8 MB 游戏池只对其中一个取 GPU 地址（进驻留集）→ 池零拷贝缓冲 +8 MB（没取地址的那个不算），先写过的 1 MB 一定在常驻里（常驻 ≥ 1 MB、≤ 8 MB）；
//   GPU 可见的视图不重复计（贴图视图 +0）
#include "../gfx/nvn/nvn_mtl.m"

static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "SETUP FAIL %s:%d %s\n", __FILE__, __LINE__, #c); exit(2); } } while (0)
#define CHECK(c, ...) do { checks++; int good_ = !!(c); failures += !good_; printf("%s ", good_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
typedef struct { uint64_t tex, pbuf, plen, ptouch, other, n; } kinds;
static kinds take(void) { kinds k; nvn_be_mem_kinds(&k.tex, &k.pbuf, &k.plen, &k.ptouch, &k.other, &k.n); return k; }

int main(void) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0); alarm(60);
        mtl_init(); printf("DEVICE %s backend=Metal%d\n", g_dev.name.UTF8String, g_m3 ? 3 : 4);
        enum { POOL = 8 << 20 };
        uint8_t *p1 = NULL, *p2 = NULL; REQUIRE(!posix_memalign((void **)&p1, 65536, POOL) && !posix_memalign((void **)&p2, 65536, POOL));
        memset(p1, 1, 1 << 20);   // 池 1 先写 1 MB
        nvn_be_pool_add(p1, POOL); nvn_be_pool_add(p2, POOL);
        kinds k0 = take();
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1024 height:1024 mipmapped:NO];
        d.storageMode = MTLStorageModePrivate; d.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
        id<MTLTexture> t = [g_dev newTextureWithDescriptor:d]; REQUIRE(t); res_add(t);
        id<MTLTexture> v = [t newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm_sRGB]; res_add(v);
        id<MTLBuffer> pb = [g_dev newBufferWithLength:2 << 20 options:MTLResourceStorageModePrivate], sb = [g_dev newBufferWithLength:1 << 20 options:MTLResourceStorageModeShared];
        REQUIRE(pb && sb); res_add(pb); res_add(sb);
        void *mb; uint64_t mo; REQUIRE(nvn_be_addr((uint64_t)(uintptr_t)p1, 64, &mb, &mo));   // 池 1 进驻留集（池 2 不取地址）
        kinds k1 = take();
        CHECK(k1.tex - k0.tex == t.allocatedSize, "私有贴图 +%llu（期望 +%lu，视图不重复计）", (unsigned long long)(k1.tex - k0.tex), (unsigned long)t.allocatedSize);
        CHECK(k1.pbuf - k0.pbuf == pb.allocatedSize, "私有缓冲 +%llu（期望 +%lu）", (unsigned long long)(k1.pbuf - k0.pbuf), (unsigned long)pb.allocatedSize);
        CHECK(k1.other - k0.other == sb.allocatedSize, "其它共享缓冲 +%llu（期望 +%lu）", (unsigned long long)(k1.other - k0.other), (unsigned long)sb.allocatedSize);
        CHECK(k1.plen - k0.plen == POOL, "游戏池零拷贝缓冲 +%llu（期望 +%d：只有取过地址的池 1）", (unsigned long long)(k1.plen - k0.plen), POOL);
        CHECK(k1.ptouch - k0.ptouch >= (1u << 20) && k1.ptouch - k0.ptouch <= POOL, "池 1 常驻 / 压缩 +%llu KB（期望 1024–8192 KB；> 1024 即驻留集把没写的页也钉进了内存）", (unsigned long long)((k1.ptouch - k0.ptouch) >> 10));
        CHECK(k1.n - k0.n == 5, "驻留集对象 +%llu（期望 +5：贴图、视图、两个缓冲、池 1）", (unsigned long long)(k1.n - k0.n));
        printf("%s t_nvn_mem_kinds: %u checks %u failures; backend Metal%d\n", failures ? "✗" : "✓", checks, failures, g_m3 ? 3 : 4);
        return failures != 0;
    }
}
