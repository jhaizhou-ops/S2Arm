// 同一存储上被别的贴图 GPU 写过的活对象贴图按 Ryujinx 语义释放（nvn_mtl.m alias_take_over / alias_overwritten / alias_dead_views）。
// 背景：11-05 时之笛 Switch 2 版阴影图几乎每帧换一个尺寸，每个尺寸是一个新的、一直活着的 NVN 贴图对象，全叠在同一块存储上
//   （Mac 120 秒局：同一池偏移上 429 张 961x961..1280x1280 深度图，存储并集 6 MB，Metal 私有贴图约 2.2 GB）；活对象持有的贴图从不放，读档进场景被系统杀。
// Switch / Ryujinx 语义：贴图 = 那段内存；别的贴图的 GPU 写落在同一段上之后，旧贴图的内容就没了（Ryujinx 贴图缓存把被覆盖的宿主贴图丢掉）。
// 期望（按上面的语义手写，不由被测实现推出）：
//   ① A 写过 → B（同存储、另一尺寸）写过 → 空提交 ALIAS_IDLE 次 → 建 C（同存储）：A 的宿主贴图从序号表与编号视图里放掉，GPU 做完后对象释放；
//      B 仍在（之后没人写过它的存储）；A 再用时建一张新的（不是原来那张）
//   ② D 写过 → E 只建不写 → 空提交 → 建 F：D 留着（它的存储没被别人写过，内容在 Switch 上还在）
//   ③ G 每次提交都写、H 同存储也写过：G 一直在用，建 I 时 G 留着
#include "../gfx/nvn/nvn_mtl.m"

static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "SETUP FAIL %s:%d %s\n", __FILE__, __LINE__, #c); exit(2); } } while (0)
#define CHECK(c, ...) do { checks++; int good_ = !!(c); failures += !good_; printf("%s ", good_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
static pool_t *g_tp; static uint8_t *g_mem;
static void make(tex_t *t, size_t off, uint32_t side) {
    memset(t, 0, sizeof *t); t->magic = MAGIC('T', 'E', 'X', 0); t->serial = nvn_new_serial();
    t->d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = NVN_FORMAT_RGBA8, .flags = NVN_TEXTURE_FLAGS_COMPRESSIBLE, .width = side, .height = side, .depth = 1, .levels = 1};
    t->pool = g_tp; t->off = (int64_t)off; t->mem = g_mem + off; nvn_tex_layout(&t->d, &t->L); nvn_be_tex_init(t);
}
static id<MTLTexture> use(tex_t *t, int write) {   // 解析（提交线程、提交里），写的话记一次 GPU 写（渲染遍挂附件时生产代码同样调 gpw_mark）
    id<MTLTexture> m = tex_mtl(t); if (write) gpw_mark(t, 0, 0, 1, 0, 0, 0, 0); return m;
}
static void submit(void) { uint64_t f = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f, 10000000000ull)); nvn_be_sub_begin(); }
static void idle(void) { for (int i = 0; i <= ALIAS_IDLE; i++) submit(); }
int main(void) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0); alarm(120);
        mtl_init(); printf("DEVICE %s backend=Metal%d\n", g_dev.name.UTF8String, g_m3 ? 3 : 4);
        enum { POOL = 32 << 20 };
        REQUIRE(!posix_memalign((void **)&g_mem, 65536, POOL)); memset(g_mem, 0, POOL);
        g_tp = calloc(1, sizeof *g_tp); REQUIRE(g_tp);
        *g_tp = (pool_t){.magic = MAGIC('P', 'O', 'O', 'L'), .flags = NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS | NVN_MEMORY_POOL_FLAGS_GPU_CACHED, .mem = g_mem, .size = POOL};
        nvn_be_pool_add(g_mem, POOL);
        nvn_be_sub_begin();
        // ①
        static tex_t A, B, C; make(&A, 0, 512); make(&B, 0, 520); make(&C, 0, 528);
        nvn_be_reg_tex(1, &A, NULL); __weak id<MTLTexture> wa;
        @autoreleasepool { id<MTLTexture> a = use(&A, 1); wa = a; pthread_mutex_lock(&g_rmu); REQUIRE(tex_by_id(1) != nil); pthread_mutex_unlock(&g_rmu); }
        submit();
        id<MTLTexture> b0 = use(&B, 1); submit(); idle();
        uint64_t dead0 = g_alias_dead; use(&C, 0); submit();
        for (int i = 0; i < 4; i++) submit();   // 延迟释放随后面几次提交的围栏完成执行
        nvn_be_drain();
        CHECK(tex_get(A.serial) == nil, "① A 被 B 写过、闲了 %d 次提交：序号表里放掉", ALIAS_IDLE + 1);
        CHECK(g_alias_dead == dead0 + 1, "① 按覆写放掉的活对象 +%llu（期望 +1）", (unsigned long long)(g_alias_dead - dead0));
        CHECK(wa == nil, "① A 原来那张 Metal 贴图（编号 1 的视图也持有它）GPU 做完后释放");
        CHECK(tex_get(B.serial) == b0, "① B 仍是原来那张（之后没人写过它的存储）");
        id<MTLTexture> a2 = use(&A, 0); CHECK(a2 != nil, "① A 再用时建一张新的");
        // ②
        static tex_t D, E, F; make(&D, 8 << 20, 512); make(&E, 8 << 20, 520); make(&F, 8 << 20, 528);
        id<MTLTexture> d0 = use(&D, 1); submit(); use(&E, 0); submit(); idle(); use(&F, 0); submit();
        CHECK(tex_get(D.serial) == d0, "② D 的存储只被建在上面的 E 盖着、没被写过：D 留着");
        // ③
        static tex_t tg, th, ti; make(&tg, 16 << 20, 512); make(&th, 16 << 20, 520); make(&ti, 16 << 20, 528);
        id<MTLTexture> g0 = use(&tg, 1); submit(); use(&th, 1); submit();
        for (int i = 0; i <= ALIAS_IDLE; i++) { use(&tg, 1); submit(); }
        use(&ti, 0); submit();
        CHECK(tex_get(tg.serial) == g0, "③ G 每次提交都在写：留着");
        nvn_be_drain();
        printf("%s t_nvn_alias_overwrite: %u checks %u failures; backend Metal%d\n", failures ? "✗" : "✓", checks, failures, g_m3 ? 3 : 4);
        return failures != 0;
    }
}
