// 同一块存储上只差 sRGB / 线性格式对的两个 NVN 贴图共用字节（nvn_mtl.m srgb_twins / srgb_twin_view / tex_upgrade；补齐上游参考实现（MIT）92f223a7）。
// Switch 语义：贴图 = 那段内存。RGBA8 与 RGBA8_SRGB 两个对象叠在同一偏移上，经一个写进去的字节，经另一个读出来就是这些字节（拷贝不做 sRGB 换算）。
//   上游症状：马车世界大奖赛片头 YUV 遍写 RGBA8 渲染目标、合成遍经 RGBA8_SRGB 贴图采样，各建各的 Metal 贴图 → 合成读到的是第一次的内容，画面冻结。
// 期望（按上面的语义手写，不由被测实现推出）：
//   ① sRGB 对象解析出来是线性对象那张 Metal 贴图的视图；不成对的格式（R32F）另有自己的贴图
//   ② 经线性对象写进 16 个纹素，经 sRGB 对象读回逐字节相同
//   ③ 线性对象为加用途被升级后（换了一张 Metal 贴图），sRGB 对象跟着读升级后的那张：写进去的新字节读回相同
//   ④ 经 sRGB 对象要求升级：升级的是父贴图，sRGB 对象仍是它的视图，线性对象也换到升级后的父贴图
// NVN_SRGB_SOURCE 可指向别的 nvn_mtl.m 副本（修前 / 负对照编同一份单测）。
#ifndef NVN_SRGB_SOURCE
#define NVN_SRGB_SOURCE "../gfx/nvn/nvn_mtl.m"
#endif
#include NVN_SRGB_SOURCE

static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "SETUP FAIL %s:%d %s\n", __FILE__, __LINE__, #c); exit(2); } } while (0)
#define CHECK(c, ...) do { checks++; int good_ = !!(c); failures += !good_; printf("%s ", good_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
static pool_t *g_tp; static uint8_t *g_mem;
static void make(tex_t *t, int format) {
    memset(t, 0, sizeof *t); t->magic = MAGIC('T', 'E', 'X', 0); t->serial = nvn_new_serial();
    t->d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = format, .width = 4, .height = 4, .depth = 1, .levels = 1, .samples = 1};
    t->pool = g_tp; t->off = 0; t->mem = g_mem; nvn_tex_layout(&t->d, &t->L); nvn_be_tex_init(t);
}
static void submit(void) { uint64_t f = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f, 10000000000ull)); nvn_be_sub_begin(); }
// 经 to 写 16 个纹素、经 from 读回（同一次提交里两次 blit，拷贝不做格式换算）
static int roundtrip(id<MTLTexture> to, id<MTLTexture> from, uint32_t seed) {
    uint32_t px[16]; for (int i = 0; i < 16; i++) px[i] = seed + (uint32_t)i * 0x01010101u;
    id<MTLBuffer> src = [g_dev newBufferWithBytes:px length:sizeof px options:MTLResourceStorageModeShared]; res_add(src);
    id<MTLBuffer> dst = [g_dev newBufferWithLength:sizeof px options:MTLResourceStorageModeShared]; res_add(dst); memset(dst.contents, 0xA5, sizeof px);
    enc_b_copy_buffer_texture(blit(), src, 0, 16, sizeof px, MTLSizeMake(4, 4, 1), to, 0, 0, MTLOriginMake(0, 0, 0));
    enc_b_copy_texture_buffer(blit(), from, 0, 0, MTLOriginMake(0, 0, 0), MTLSizeMake(4, 4, 1), dst, 0, 16, sizeof px);
    submit();
    return !memcmp(dst.contents, px, sizeof px);
}
int main(void) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0); alarm(120);
        mtl_init(); printf("DEVICE %s backend=Metal%d\n", g_dev.name.UTF8String, g_m3 ? 3 : 4);
        enum { POOL = 1 << 20 };
        REQUIRE(!posix_memalign((void **)&g_mem, 65536, POOL)); memset(g_mem, 0, POOL);
        g_tp = calloc(1, sizeof *g_tp); REQUIRE(g_tp);
        *g_tp = (pool_t){.magic = MAGIC('P', 'O', 'O', 'L'), .flags = NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS | NVN_MEMORY_POOL_FLAGS_GPU_CACHED, .mem = g_mem, .size = POOL};
        nvn_be_pool_add(g_mem, POOL);
        nvn_be_sub_begin();
        static tex_t lin, srgb, other; make(&lin, NVN_FORMAT_RGBA8); make(&srgb, NVN_FORMAT_RGBA8_SRGB); make(&other, NVN_FORMAT_R32F);
        id<MTLTexture> base = tex_mtl(&lin), view = tex_mtl(&srgb), own = tex_mtl(&other);
        REQUIRE(base && view && own);
        // ①
        CHECK(view.pixelFormat == MTLPixelFormatRGBA8Unorm_sRGB, "① sRGB 对象的格式是 RGBA8_SRGB（%lu）", (unsigned long)view.pixelFormat);
        CHECK(view.parentTexture == base, "① sRGB 对象是线性对象那张贴图的视图");
        CHECK(own != base && own.parentTexture == nil, "① 不成对的格式（R32F）有自己的贴图");
        // ②
        CHECK(roundtrip(base, view, 0x44332211u), "② 经线性对象写的 16 个纹素，经 sRGB 对象读回逐字节相同");
        // ③
        id<MTLTexture> up = tex_upgrade(&lin, base, MTLTextureUsageShaderWrite, base.pixelFormat);
        CHECK(up != base && tex_mtl(&lin) == up, "③ 线性对象升级成另一张贴图");
        id<MTLTexture> view2 = tex_mtl(&srgb);
        CHECK(view2.parentTexture == up && view2.pixelFormat == MTLPixelFormatRGBA8Unorm_sRGB, "③ sRGB 对象换成升级后那张的视图");
        CHECK(roundtrip(up, view2, 0x88776655u), "③ 经升级后的线性贴图写的纹素，经 sRGB 对象读回逐字节相同");
        // ④
        id<MTLTexture> up2 = tex_upgrade(&srgb, view2, MTLTextureUsageRenderTarget, view2.pixelFormat);
        id<MTLTexture> lin3 = tex_mtl(&lin);
        CHECK(up2.pixelFormat == MTLPixelFormatRGBA8Unorm_sRGB && up2.parentTexture == lin3 && lin3 != up && tex_mtl(&srgb) == up2,
              "④ 经 sRGB 对象升级：升级父贴图、sRGB 对象仍是它的视图、线性对象换到新父贴图");
        CHECK(roundtrip(lin3, up2, 0xccbbaa99u), "④ 升级后仍共用字节");
        for (int i = 0; i < 4; i++) submit();
        nvn_be_drain();
        printf("%s t_nvn_srgb_alias: %u checks %u failures; backend Metal%d\n", failures ? "✗" : "✓", checks, failures, g_m3 ? 3 : 4);
        return failures != 0;
    }
}
