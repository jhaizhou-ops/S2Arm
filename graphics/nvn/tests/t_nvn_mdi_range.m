// 间接计数多绘的整段记录回放（nvn_mtl.m draw_multi / mdx_run 的范围批；补齐上游参考实现（MIT）c7ba23df）：真实 Metal 管线、生产回放入口 nvn_be_exec、GPU 读回。
// Switch 语义：MultiDraw*IndirectCount(参数记录, 计数地址, 最多 max 条, 步长) 画 min(计数, max) 条，第 i 条读 ind + i × 步长 的 {顶点数, 实例数, 首顶点, 首实例}。
// 夹具：每条记录 {3, 1, 0, 首实例 = 它的序号}，顶点着色器按实例号（Metal 的 instance_id 含首实例）把一个小三角形放到 128x128 目标的第 instance_id 个像素上，
//   片元写白；画完数白像素 = 活着的绘制数（各画各的像素，互不重叠；目标 128x128）。期望按上面的语义手写，不由被测实现推出：
//   ① max 2000、步长 16、计数 1500 → 1500 个像素，且第 1024 号之后的像素有（原先截到 1,024 条）
//   ② 计数 0 → 0 个
//   ③ 步长 0（每条读同一条记录，首实例 7）、计数 1300 → 只有 7 号一个像素，宿主编了 1300 条（读一次计数、只画活的）
//   ④ max = INT_MAX、计数 3 → 3 个像素（超过掩码表容量：读一次计数，不编几十亿条）
//   ⑤ 负步长：ind 指最后一条记录、步长 -16、计数 1100 → 1100 个像素，正是最后 1100 条记录的序号
//   ⑥ max 9000、计数 6000：超过掩码一批（4096 条），第二批从第一批没收的那条起 → 0..5999 号 6000 个像素
#ifndef NVN_MDI_SOURCE
#define NVN_MDI_SOURCE "../gfx/nvn/nvn_mtl.m"
#endif
#include NVN_MDI_SOURCE   // NVN_MDI_SOURCE：负对照编同一份单测

static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "SETUP FAIL %s:%d %s\n", __FILE__, __LINE__, #c); exit(2); } } while (0)
#define CHECK(c, ...) do { checks++; int good_ = !!(c); failures += !good_; printf("%s ", good_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
enum { W = 128, NREC = 8192, POOL = 1 << 20, CNT_OFF = 0xC0000, REC_OFF = 0x40000 };
static NSString *const source = @"#include <metal_stdlib>\nusing namespace metal;\n"
"vertex float4 dot(uint v [[vertex_id]], uint i [[instance_id]]) {\n"
"  float s = 2.0 / 128.0; float2 o = float2(float(i % 128u), float(i / 128u)) * s - 1.0;\n"
"  float2 p = o + (v == 1u ? float2(1.5 * s, 0) : v == 2u ? float2(0, 1.5 * s) : float2(0)); return float4(p, 0, 1); }\n"
"fragment float4 white() { return float4(1); }\n";
static NvShader *shader(id<MTLLibrary> library, NSString *name, int stage) {
    NvShader *s = [NvShader new]; s->stage = stage;
    s->fn = [library newFunctionWithName:name]; REQUIRE(s->fn);
    strlcpy(s->key, stage ? "dddddddddddddddd_b" : "cccccccccccccccc_b", sizeof s->key);
    s->rf.pos_attr = -1; s->rf.has_user = stage ? 2 : 1;
    if (stage) { s->rf.color_known = 1; s->rf.color_mask = 1; }
    return s;
}
static uint8_t *g_mem; static tex_t g_rt;
static void clear_rt(void) { p_clear_tex c = {.tex = &g_rt, .value_type = CLEAR_TEX_FLOAT, .r = {0, 0, 0, W, W, 1}, .mask = 15}; clear_tex(&c); }
static void finish(void) { uint64_t f = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f, 10000000000ull)); REQUIRE(!mtl_last_commit_error()); }
static int g_flip = -1;   // 目标的行序与顶点着色器的 y 是否相反（窗口原点左下时回放会翻 y）：由 ③ 前的单像素例定，之后各例同用
static int white_pixels(uint8_t *lit) {   // GPU 读回（不经生产读回路径），lit[i]：第 i 号像素（行优先，按 g_flip 把行序对回顶点着色器的排法）
    id<MTLTexture> image = tex_mtl(&g_rt); REQUIRE(image);
    id<MTLBuffer> buffer = [g_dev newBufferWithLength:W * W * 4 options:MTLResourceStorageModeShared]; REQUIRE(buffer);
    id<MTLCommandQueue> queue = [g_dev newCommandQueue]; id<MTLCommandBuffer> cb = [queue commandBuffer]; id<MTLBlitCommandEncoder> enc = [cb blitCommandEncoder];
    [enc copyFromTexture:image sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(W, W, 1) toBuffer:buffer destinationOffset:0 destinationBytesPerRow:W * 4 destinationBytesPerImage:W * W * 4];
    [enc endEncoding]; [cb commit]; [cb waitUntilCompleted]; REQUIRE(cb.status == MTLCommandBufferStatusCompleted);
    const uint8_t *b = buffer.contents; int n = 0;
    for (int y = 0; y < W; y++) for (int x = 0; x < W; x++) { int on = b[(y * W + x) * 4] > 128; n += on; if (lit) lit[(g_flip > 0 ? W - 1 - y : y) * W + x] = (uint8_t)on; }
    return n;
}
static int run(int64_t stride, int32_t max, uint32_t count, uint64_t first_rec, uint8_t *lit, uint64_t *encoded) {
    memcpy(g_mem + CNT_OFF, &count, 4);
    nvn_be_sub_begin(); clear_rt();
    struct { op_hdr h; p_multi_draw m; op_hdr end; } cmd = {
        .h = {OP_MULTI_DRAW, sizeof(op_hdr) + sizeof(p_multi_draw)},
        .m = {.ind = (uint64_t)(uintptr_t)(g_mem + REC_OFF) + first_rec * 16, .cnt = (uint64_t)(uintptr_t)(g_mem + CNT_OFF), .stride = stride, .max = max, .prim = NVN_DRAW_PRIMITIVE_TRIANGLES, .itype = -1},
        .end = {OP_END, sizeof(op_hdr)}};
    uint64_t d0 = g_stat_draw;
    nvn_be_exec((const uint8_t *)&cmd); finish();
    if (encoded) *encoded = g_stat_draw - d0;
    return white_pixels(lit);
}
int main(void) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0); alarm(120);
        char map[] = "/tmp/t_mdi_range_map_XXXXXX"; int fd = mkstemp(map); REQUIRE(fd >= 0); close(fd);
        char user[] = "/tmp/t_mdi_range_user_XXXXXX"; fd = mkstemp(user); REQUIRE(fd >= 0); close(fd);
        setenv("DM_NVN_SHMAP", map, 1); setenv("DM_PSO_USER", user, 1); setenv("DM_PSO_ARCHIVE", "0", 1);
        mtl_init(); printf("DEVICE %s backend=Metal%d\n", g_dev.name.UTF8String, g_m3 ? 3 : 4);
        const op_hdr empty = {OP_END, sizeof(op_hdr)}; nvn_be_exec((const uint8_t *)&empty);
        NSError *error = nil; id<MTLLibrary> library = [g_dev newLibraryWithSource:source options:nil error:&error];
        if (!library) fprintf(stderr, "MSL: %s\n", error.localizedDescription.UTF8String); REQUIRE(library);
        NvProg *program = [NvProg new]; program->sh[0] = shader(library, @"dot", 0); program->sh[1] = shader(library, @"white", 1);
        prog_t p = {.magic = MAGIC('P', 'R', 'O', 'G'), .serial = nvn_new_serial()}; serial_put(p.serial, program);
        REQUIRE(!posix_memalign((void **)&g_mem, 65536, POOL)); memset(g_mem, 0, POOL);
        pool_t *pool = calloc(1, sizeof *pool); REQUIRE(pool);
        *pool = (pool_t){.magic = MAGIC('P', 'O', 'O', 'L'), .flags = NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED, .mem = g_mem, .size = POOL};
        nvn_be_pool_add(g_mem, POOL);
        for (uint32_t i = 0; i < NREC; i++) { uint32_t r[4] = {3, 1, 0, i}; memcpy(g_mem + REC_OFF + 16 * i, r, 16); }
        memset(&g_rt, 0, sizeof g_rt); g_rt.magic = MAGIC('T', 'E', 'X', 0); g_rt.serial = nvn_new_serial();
        g_rt.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = NVN_FORMAT_RGBA8, .width = W, .height = W, .depth = 1, .levels = 1, .samples = 1};
        g_rt.pool = pool; g_rt.off = 0; g_rt.mem = g_mem; nvn_tex_layout(&g_rt.d, &g_rt.L); nvn_be_tex_init(&g_rt);
        nvn_be_sub_begin(); state_reset(); S.prog = &p;
        memset(&R.rt, 0, sizeof R.rt); R.rt.n = 1; R.rt.color[0] = &g_rt; R.has_rt = 1; g_pso_dirty = 1; args_dirty_all();
        finish();
        static uint8_t lit[W * W]; uint64_t enc = 0; int n, ok;
        {   // 行序：计数 1、只画 0 号记录（首实例 0）→ 亮的像素在第 0 行还是最后一行
            g_flip = 0; n = run(16, 2000, 1, 0, lit, NULL); REQUIRE(n == 1); g_flip = lit[0] ? 0 : lit[(W - 1) * W] ? 1 : -1; REQUIRE(g_flip >= 0);
            printf("行序：目标第 %s 行是 0 号像素\n", g_flip ? "最后一" : "0"); }
        n = run(16, 2000, 1500, 0, lit, NULL); ok = 1; for (int i = 0; i < W * W; i++) ok &= lit[i] == (i < 1500);
        CHECK(n == 1500 && ok, "① max 2000、计数 1500：%d 个像素（期望 1500，且正是 0..1499 号；第 1024 号起 %s）", n, lit[1024] && lit[1499] ? "有" : "没有");
        n = run(16, 2000, 0, 0, NULL, NULL); CHECK(n == 0, "② 计数 0：%d 个像素", n);
        { uint32_t r[4] = {3, 1, 0, 7}; memcpy(g_mem + REC_OFF + 16 * 3000, r, 16); }
        n = run(0, 2000, 1300, 3000, lit, &enc); CHECK(n == 1 && lit[7] && enc == 1300, "③ 步长 0、计数 1300：%d 个像素（7 号 %s），编了 %llu 条", n, lit[7] ? "亮" : "不亮", (unsigned long long)enc);
        { uint32_t r[4] = {3, 1, 0, 3000}; memcpy(g_mem + REC_OFF + 16 * 3000, r, 16); }
        n = run(16, 0x7fffffff, 3, 0, NULL, &enc); CHECK(n == 3 && enc == 3, "④ max INT_MAX、计数 3：%d 个像素、编了 %llu 条", n, (unsigned long long)enc);
        n = run(-16, 2000, 1100, NREC - 1, lit, NULL); ok = 1; for (int i = 0; i < W * W; i++) ok &= lit[i] == (i >= NREC - 1100 && i < NREC);
        CHECK(n == 1100 && ok, "⑤ 负步长、计数 1100：%d 个像素（期望最后 1100 条记录的序号）", n);
        n = run(16, 9000, 6000, 0, lit, NULL); ok = 1; for (int i = 0; i < W * W; i++) ok &= lit[i] == (i < 6000);
        CHECK(n == 6000 && ok, "⑥ max 9000、计数 6000（超过一批 4096 条，要分两批掩码）：%d 个像素（期望正是 0..5999 号）", n);
        unlink(map); unlink(user);
        printf("%s t_nvn_mdi_range: %u checks %u failures; backend Metal%d\n", failures ? "✗" : "✓", checks, failures, g_m3 ? 3 : 4);
        return failures != 0;
    }
}
