// 只放贴图的池上传贴图时不进常驻集合（nvn_mtl.m up_tex_src；上游参考实现（MIT）1d4b8e82 / b1d7c707 up_big_src 的普通池那一半）。
// 背景：GPU 解交错上传按 nvn_be_addr 查池 → pool_res 把整池放进常驻集合、提交，之后一直不出来；iOS 把常驻的无拷贝缓冲整块读进内存并钉成 wired。
//   时之笛（11-06 测试机，不开原始池表）单个命令缓冲要 5.1–5.8 GB（内核 maxWired 8 GB）；上游实测第一个场景只放贴图的池占 4.6 GB、由它们建的贴图 1.6 GB。
// 期望（按「没给出过 GPU 地址、还没常驻的池只给这张贴图那段临时建缓冲，随上传批退役」的语义手写，不由被测实现推出）：
//   池里贴图区之外全 0xAA，贴图（256×256 RGBA8，块线性）存储全是字 0x11223344：解交错只搬字节，不论布局每个纹素都 = 44 33 22 11。
//   贴图放在池内 1 MiB + 0x200（不在页边界上）：源缓冲从贴图所在页起，偏移算错（如当成 0）就会读进前面的 0xAA。
//   ① 池 P 没给出过地址：上传一张 → P 不在常驻集合（res = 0）、常驻池数不变；临时源 +1；读回每个纹素 = 44 33 22 11
//   ② 池 Q 给出过地址（nvn_be_pool_addressed，GetBufferAddress 等的去处）：上传 → Q 照旧进常驻（res = 1）、常驻池数 +1；临时源不变；内容对
//   ③ 池 R 没给过地址但已常驻（缓冲绑定等别的 GPU 用途查过它）：上传 → 临时源不变（直接用已常驻的池缓冲）；内容对
// 反证（修前）：同一单测编改前的 nvn_mtl.m → ① 的 res = 1、常驻池数 +1、临时源计数不存在（编不过时把 ① 的计数检查换成 0 再看前两条）
#include "../gfx/nvn/nvn_mtl.m"

static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "SETUP FAIL %s:%d %s\n", __FILE__, __LINE__, #c); exit(2); } } while (0)
#define CHECK(c, ...) do { checks++; int good_ = !!(c); failures += !good_; printf("%s ", good_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
enum { POOL = 4 << 20, TEX_OFF = (1 << 20) + 0x200, SIDE = 256 };
typedef struct { pool_t p; uint8_t *mem; int idx; } box;
static void make_pool(box *b) {
    REQUIRE(!posix_memalign((void **)&b->mem, 65536, POOL)); memset(b->mem, 0xAA, POOL);
    b->p = (pool_t){.magic = MAGIC('P', 'O', 'O', 'L'), .flags = NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED, .mem = b->mem, .size = POOL};
    nvn_be_pool_add(b->mem, POOL);
    b->idx = -1; for (int i = 0; i < g_npool; i++) if (g_pools[i].key == b->mem) b->idx = i;
    REQUIRE(b->idx >= 0);
}
static void make_tex(tex_t *t, box *b) {
    memset(t, 0, sizeof *t); t->magic = MAGIC('T', 'E', 'X', 0); t->serial = nvn_new_serial();
    t->d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = NVN_FORMAT_RGBA8, .width = SIDE, .height = SIDE, .depth = 1, .levels = 1};
    t->pool = &b->p; t->off = TEX_OFF; t->mem = b->mem + TEX_OFF; nvn_tex_layout(&t->d, &t->L);
    REQUIRE(t->L.size >= (uint64_t)SIDE * SIDE * 4 && TEX_OFF + t->L.size + 0x200 <= POOL);
    for (uint64_t i = 0; i < t->L.size / 4; i++) ((uint32_t *)t->mem)[i] = 0x11223344u;   // 上传前写好：上传会给这段加写保护
    nvn_be_tex_init(t); nvn_be_tex_cpu_written(t);   // CPU 写过的块线性贴图：走随包上传（pkg_upload_）
}
static unsigned wrong_texels(id<MTLTexture> m) {   // 旧式队列拷到共享缓冲读回
    static id<MTLCommandQueue> q; if (!q) q = [g_dev newCommandQueue];
    id<MTLBuffer> out = [g_dev newBufferWithLength:SIDE * SIDE * 4 options:MTLResourceStorageModeShared]; REQUIRE(out);
    id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLBlitCommandEncoder> e = [cb blitCommandEncoder];
    [e copyFromTexture:m sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(SIDE, SIDE, 1) toBuffer:out destinationOffset:0 destinationBytesPerRow:SIDE * 4 destinationBytesPerImage:SIDE * SIDE * 4];
    [e endEncoding]; [cb commit]; [cb waitUntilCompleted]; REQUIRE(cb.status == MTLCommandBufferStatusCompleted);
    unsigned n = 0; const uint32_t *w = out.contents; for (int i = 0; i < SIDE * SIDE; i++) n += w[i] != 0x11223344u;
    return n;
}
static id<MTLTexture> upload(tex_t *t) {   // 提交线程上、提交里第一次解析 = 上传；提交做完、上传批退役
    id<MTLTexture> m = tex_mtl(t); REQUIRE(m);
    uint64_t f = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f, 10000000000ull)); nvn_be_drain(); nvn_be_sub_begin();
    return m;
}
int main(void) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0); alarm(120);
        mtl_init(); printf("DEVICE %s backend=Metal%d deswizzle on GPU %d page %d\n", g_dev.name.UTF8String, g_m3 ? 3 : 4, g_nvn_deswz_gpu, getpagesize());
        REQUIRE(g_nvn_deswz_gpu);   // 被测的是 GPU 解交错的取源
        nvn_be_sub_begin();
        // ①
        static box P; static tex_t tp; make_pool(&P); make_tex(&tp, &P);
        int r0 = g_pool_res_n; uint64_t s0 = g_up_src_n;
        id<MTLTexture> mp = upload(&tp);
        CHECK(!g_pools[P.idx].res, "① 没给出过地址的池上传后不在常驻集合（res = %d）", g_pools[P.idx].res);
        CHECK(g_pool_res_n == r0, "① 常驻池数 %d → %d（期望不变）", r0, g_pool_res_n);
        CHECK(g_up_src_n == s0 + 1, "① 临时源 +%llu（期望 +1）", (unsigned long long)(g_up_src_n - s0));
        unsigned bad = wrong_texels(mp); CHECK(!bad, "① 读回 %d 个纹素里 %u 个不是 44 33 22 11", SIDE * SIDE, bad);
        // ②
        static box Q; static tex_t tq; make_pool(&Q); nvn_be_pool_addressed(Q.mem, POOL); make_tex(&tq, &Q);
        r0 = g_pool_res_n; s0 = g_up_src_n;
        id<MTLTexture> mq = upload(&tq);
        CHECK(g_pools[Q.idx].res == 1, "② 给出过地址的池照旧进常驻（res = %d）", g_pools[Q.idx].res);
        CHECK(g_pool_res_n == r0 + 1, "② 常驻池数 %d → %d（期望 +1）", r0, g_pool_res_n);
        CHECK(g_up_src_n == s0, "② 临时源 +%llu（期望 0）", (unsigned long long)(g_up_src_n - s0));
        bad = wrong_texels(mq); CHECK(!bad, "② 读回不对的纹素 %u", bad);
        // ③
        static box R; static tex_t tr; make_pool(&R);
        { void *b; uint64_t o; REQUIRE(nvn_be_addr((uint64_t)(uintptr_t)R.mem, 256, &b, &o)); REQUIRE(g_pools[R.idx].res); }
        make_tex(&tr, &R);
        s0 = g_up_src_n;
        id<MTLTexture> mr = upload(&tr);
        CHECK(g_up_src_n == s0, "③ 已常驻的池不另建临时源（+%llu，期望 0）", (unsigned long long)(g_up_src_n - s0));
        bad = wrong_texels(mr); CHECK(!bad, "③ 读回不对的纹素 %u", bad);
        nvn_be_drain();
        printf("%s t_nvn_up_tex_src: %u checks %u failures; backend Metal%d\n", failures ? "✗" : "✓", checks, failures, g_m3 ? 3 : 4);
        return failures != 0;
    }
}
