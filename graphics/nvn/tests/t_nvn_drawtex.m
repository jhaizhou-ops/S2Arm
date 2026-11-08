// DrawTexture（nvn_mtl.m draw_tex，10-30 Bare Knuckle IV 报未实现）：直接包含生产 nvn_mtl.m，真 Metal 设备、真游戏内存池与贴图登记，一次提交回放后读回目标逐像素比。
// 期望按 NVN / Ryujinx 的定义手算，不跑被测实现：源 4×4，纹素 (x, y) = RGBA8 (40x+10, 40y+10, 200, 255)；目标 8×8 先填 (1, 2, 3, 4)；采样器最近点、钳边。
//   ① 目标 (2,2)→(6,6)、源 (0,0)→(4,4)：目标像素 (2+i, 2+j) = 源 (i, j)，矩形外不动
//   ② 目标 (6,2)→(2,6)（x 反向）、源同上：目标像素 (2+i, 2+j) = 源 (3−i, j)（Ryujinx：目标反向时源也反着走）
//   ③ 目标 (0,0)→(8,8)、源 (0,0)→(4,4)：每个源纹素铺 2×2，目标 (x, y) = 源 (x/2, y/2)
//   状态：画完后游戏的视口 / 剔除 / 深度测试原样（draw_tex 只临时改）
#include "../gfx/nvn/nvn_mtl.m"

static unsigned failures, checks;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "FAIL setup %s:%d: %s\n", __FILE__, __LINE__, #c); exit(1); } } while (0)
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) failures++; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)

static pool_t *g_pool_t;
static void make_tex(tex_t *t, size_t off, int w, int h) {
    memset(t, 0, sizeof *t); t->magic = MAGIC('T', 'E', 'X', 0); t->serial = nvn_new_serial();
    t->d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = NVN_FORMAT_RGBA8, .width = (uint32_t)w, .height = (uint32_t)h, .depth = 1, .levels = 1};
    t->pool = g_pool_t; t->off = off; t->mem = g_pool_t->mem + off; nvn_tex_layout(&t->d, &t->L); nvn_be_tex_init(t);
    REQUIRE(tex_mtl(t));
}
// 自己的队列直接读写贴图（不经被测的上传 / 读回路径）
static void fill(id<MTLTexture> t, const uint32_t *px) {
    NSUInteger w = t.width, h = t.height; id<MTLBuffer> b = [g_dev newBufferWithBytes:px length:w * h * 4 options:MTLResourceStorageModeShared];
    id<MTLCommandQueue> q = [g_dev newCommandQueue]; id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLBlitCommandEncoder> e = [cb blitCommandEncoder];
    [e copyFromBuffer:b sourceOffset:0 sourceBytesPerRow:w * 4 sourceBytesPerImage:w * h * 4 sourceSize:MTLSizeMake(w, h, 1) toTexture:t destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
    [e endEncoding]; [cb commit]; [cb waitUntilCompleted]; REQUIRE(cb.status == MTLCommandBufferStatusCompleted);
}
static void readback(id<MTLTexture> t, uint32_t *px) {
    NSUInteger w = t.width, h = t.height; id<MTLBuffer> b = [g_dev newBufferWithLength:w * h * 4 options:MTLResourceStorageModeShared];
    id<MTLCommandQueue> q = [g_dev newCommandQueue]; id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLBlitCommandEncoder> e = [cb blitCommandEncoder];
    [e copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, 1) toBuffer:b destinationOffset:0 destinationBytesPerRow:w * 4 destinationBytesPerImage:w * h * 4];
    [e endEncoding]; [cb commit]; [cb waitUntilCompleted]; REQUIRE(cb.status == MTLCommandBufferStatusCompleted);
    memcpy(px, b.contents, w * h * 4);
}
static uint32_t src_px(int x, int y) { return (uint32_t)(40 * x + 10) | (uint32_t)(40 * y + 10) << 8 | 200u << 16 | 255u << 24; }   // RGBA8 little endian: R in the low byte
static const uint32_t BG = 1u | 2u << 8 | 3u << 16 | 4u << 24;

static void run(const char *name, float d0, float d1, float d2, float d3, uint32_t (^want)(int x, int y)) {
    static tex_t src, dst; static size_t next = 0;
    make_tex(&src, next, 4, 4); next += 65536; make_tex(&dst, next, 8, 8); next += 65536;
    uint32_t s[16], bg[64]; for (int y = 0; y < 4; y++) for (int x = 0; x < 4; x++) s[y * 4 + x] = src_px(x, y);
    for (int i = 0; i < 64; i++) bg[i] = BG;
    // 新贴图的清零（tex_zero_fill）在提交线程上排进下一次提交：先空提交一次让它落地，再用自己的队列写纹素（否则从第二次起清零盖在写入之后，源读成 0）
    nvn_be_sub_begin(); { uint64_t f0 = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f0, 10000000000ull)); }
    fill(tex_mtl(&src), s); fill(tex_mtl(&dst), bg);
    nvn_be_sub_begin();
    nvn_be_reg_tex(1, &src, NULL);
    samp_par sp; memset(&sp, 0, sizeof sp); sp.lod_max = 1000; nvn_be_reg_samp(1, &sp);   // nearest, clamp to edge (wrap 0)
    state_reset();
    S.poly.cull = NVN_FACE_BACK; S.has_vp = 1; S.vp[0][0] = 1; S.vp[0][1] = 1; S.vp[0][2] = 3; S.vp[0][3] = 3; S.ds.dt = 1;   // the game's state, to be put back
    memset(&R.rt, 0, sizeof R.rt); R.rt.n = 1; R.rt.color[0] = &dst; R.has_rt = 1;
    p_draw_tex t = {.handle = 1 | 1ull << 20, .dst = {d0, d1, d2, d3}, .src = {0, 0, 4, 4}};
    draw_tex(&t);
    VERIFY(S.poly.cull == NVN_FACE_BACK && S.has_vp && S.vp[0][0] == 1 && S.vp[0][2] == 3 && S.ds.dt == 1, "%s：画完后游戏的剔除 / 视口 / 深度测试原样", name);
    rp_end();
    uint64_t fence = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(fence, 10000000000ull)); REQUIRE(!mtl_last_commit_error());
    uint32_t got[64]; readback(tex_mtl(&dst), got);
    int bad = 0, bx = -1, by = -1; uint32_t bw = 0, bg2 = 0;
    for (int y = 0; y < 8; y++) for (int x = 0; x < 8; x++) { uint32_t w = want(x, y); if (got[y * 8 + x] != w && !bad++) { bx = x; by = y; bw = w; bg2 = got[y * 8 + x]; } }
    VERIFY(!bad, "%s：64 个像素逐个按手算（%d 处不符%s）", name, bad, bad ? [NSString stringWithFormat:@"，首个 (%d,%d) 期望 %08x 实得 %08x", bx, by, bw, bg2].UTF8String : "");
}

int main(void) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0); alarm(60);
        mtl_init(); printf("DEVICE %s backend=Metal%d\n", g_dev.name.UTF8String, g_m3 ? 3 : 4);
        uint8_t *memory = NULL; REQUIRE(!posix_memalign((void **)&memory, 65536, 1 << 20)); memset(memory, 0, 1 << 20);
        g_pool_t = calloc(1, sizeof *g_pool_t); REQUIRE(g_pool_t);
        *g_pool_t = (pool_t){.magic = MAGIC('P', 'O', 'O', 'L'), .flags = NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS | NVN_MEMORY_POOL_FLAGS_GPU_CACHED, .mem = memory, .size = 1 << 20};
        nvn_be_pool_add(memory, 1 << 20);
        run("② x 反向", 6, 2, 2, 6, ^uint32_t(int x, int y) { return x >= 2 && x < 6 && y >= 2 && y < 6 ? src_px(3 - (x - 2), y - 2) : BG; });
        run("① 1:1", 2, 2, 6, 6, ^uint32_t(int x, int y) { return x >= 2 && x < 6 && y >= 2 && y < 6 ? src_px(x - 2, y - 2) : BG; });
        run("③ 放大 2 倍", 0, 0, 8, 8, ^uint32_t(int x, int y) { return src_px(x / 2, y / 2); });
        nvn_be_drain();
        printf("%s t_nvn_drawtex：%u 项，%u 项失败（%s）\n", failures ? "✗" : "✓", checks, failures, g_m3 ? "Metal 3" : "Metal 4");
        return failures != 0;
    }
}
