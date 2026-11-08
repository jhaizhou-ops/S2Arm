// 已销毁纹理在一次提交里的去留（缺口 #3，11-05 时之笛 3D 场景预研；参照 上游参考实现 PR #1299 commit 2 / 3，MIT）。生产 nvn_mtl.m（包含）+ 真 Metal 设备。
// NVN 语义（与被测实现无关）：池里登记的描述符只指存储和布局，贴图对象 Finalize 之后描述符照样能用；同一份描述符在同一次提交里解析两次，GPU 读的是同一块存储。
// 期望（手算）：
//   ① 一次提交里先后解析 N = NGHOST + 16 = 528 个已销毁的缓冲纹理（各自独占一段池存储，不进共享表，只能落幽灵环），再按原顺序解析一遍：
//      两遍 528/528 是同一个 Metal 对象（同一次提交里不重建）。改前：环只有 512 格，第一遍末尾已挤掉前 16 个，第二遍连锁重建 → 同一对象远少于 528
//   ② 提交结束（围栏过后）：幽灵环留 512 个（序号 16..527），本次提交暂留表清空；环外的 528 − 512 = 16 个（序号 0..15）在围栏后出驻留集，环里的 512 个仍驻留
//   ③ 512 个已销毁的贴图对象各自建在同一块存储、同一描述上（共享表持有那张贴图），在一次提交里逐个解析：每个都解析到共享表那张贴图；
//      幽灵环放入次数 +0、序号表代号 g_ser_gen +0（不再每个挤一格环、让全部纹理 ID 缓存重查）。改前：放入 +512、代号 +512
// 负对照（11-05 手工做过，写在报告里）：去掉 tex_get / tex_put 里「编码中记进 g_ghost_active」两处 → ① 红；去掉 tex_mtl_ 里已销毁共享直接返回那一行 → ③ 红
#include "../gfx/nvn/nvn_mtl.m"

static unsigned checks, fails;
#define REQUIRE(x) do { if (!(x)) { fprintf(stderr, "FAIL setup %s:%d %s\n", __FILE__, __LINE__, #x); exit(2); } } while (0)
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) fails++; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
enum { POOL_SIZE = 4 << 20, N = NGHOST + 16, STRIDE = 256, SHARED_OFF = 2 << 20, M = 512 };
static pool_t g_pool;
static tex_t make(nvn_texdesc d, int64_t off) {   // 一个贴图对象：Initialize（活）→ 留一份快照（池登记时就是这样存的）→ Finalize（死），返回快照
    tex_t t; memset(&t, 0, sizeof t); t.magic = MAGIC('T', 'E', 'X', 0); t.serial = nvn_new_serial(); t.d = d;
    t.pool = &g_pool; t.off = off; t.mem = g_pool.mem + off; nvn_tex_layout(&t.d, &t.L);
    nvn_be_tex_init(&t);
    return t;
}
static int resident(id o) { pthread_mutex_lock(&g_res_mu); int r = [g_res_objects containsObject:o]; pthread_mutex_unlock(&g_res_mu); return r; }
int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IOLBF, 0);
    mtl_init();
    uint8_t *mem = NULL; REQUIRE(!posix_memalign((void **)&mem, 65536, POOL_SIZE)); memset(mem, 0, POOL_SIZE);
    g_pool = (pool_t){.magic = MAGIC('P', 'O', 'O', 'L'), .flags = NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED, .mem = mem, .size = POOL_SIZE};
    nvn_be_pool_add(mem, POOL_SIZE);
    {   // ① ②
        tex_t *snap = calloc(N, sizeof *snap); REQUIRE(snap);
        for (int i = 0; i < N; i++) { tex_t t = make((nvn_texdesc){.target = NVN_TEXTURE_TARGET_BUFFER, .format = NVN_FORMAT_R32F, .width = 16, .height = 1, .depth = 1, .levels = 1}, (int64_t)i * STRIDE);
            snap[i] = t; nvn_be_tex_release(&t); }
        nvn_be_sub_begin();
        NSMutableArray *first = [NSMutableArray arrayWithCapacity:N];
        for (int i = 0; i < N; i++) { id<MTLTexture> o = tex_mtl(&snap[i]); REQUIRE(o); [first addObject:o]; }
        int same = 0; for (int i = 0; i < N; i++) same += tex_mtl(&snap[i]) == first[i];
        VERIFY(same == N, "① 一次提交里 %d 个已销毁纹理解析两遍：同一对象 %d / %d（期望 %d）", N, same, N, N);
        uint64_t kept0 = g_ghost_kept;
        uint64_t f = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f, 10000000000ull)); REQUIRE(!mtl_last_commit_error()); defer_drain();
        int out = 0, in = 0;   // the completion handler drains the deferred releases on its own thread: wait (at most 2 s) until it is done
        for (int k = 0; k < 200; k++) { out = in = 0; for (int i = 0; i < N; i++) { int r = resident(first[i]); if (i < N - NGHOST) out += !r; else in += r; }
            if (out == N - NGHOST) break; usleep(10000); defer_drain(); }
        VERIFY(g_ghost.n == NGHOST && g_ghost_active.n == 0 && g_ghost_kept - kept0 == (uint64_t)(N - NGHOST),
               "② 提交结束：环里 %u（期望 %d）、暂留表 %u（期望 0）、环外放掉 %llu（期望 %d）", g_ghost.n, NGHOST, g_ghost_active.n, (unsigned long long)(g_ghost_kept - kept0), N - NGHOST);
        VERIFY(out == N - NGHOST && in == NGHOST, "② 围栏后：序号 0..15 出驻留集 %d / %d、序号 16..527 仍驻留 %d / %d", out, N - NGHOST, in, NGHOST);
        free(snap);
    }
    {   // ③
        nvn_texdesc d = {.target = NVN_TEXTURE_TARGET_2D, .format = NVN_FORMAT_RGBA8, .width = 16, .height = 16, .depth = 1, .levels = 1};
        tex_t live = make(d, SHARED_OFF);
        nvn_be_sub_begin();
        id<MTLTexture> shared = tex_mtl(&live); REQUIRE(shared);
        uint64_t puts0 = g_ghost_puts, gen0 = g_ser_gen; int same = 0;
        for (int k = 0; k < M; k++) { tex_t t = make(d, SHARED_OFF); tex_t s = t; nvn_be_tex_release(&t); same += tex_mtl(&s) == shared; }
        uint64_t puts = g_ghost_puts - puts0, gen = g_ser_gen - gen0;
        uint64_t f = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f, 10000000000ull)); REQUIRE(!mtl_last_commit_error());
        VERIFY(same == M, "③ %d 个已销毁对象建在共享存储上：解析到共享贴图 %d / %d", M, same, M);
        VERIFY(puts == 0 && gen == 0, "③ 幽灵环放入 +%llu（期望 0）、序号表代号 +%llu（期望 0）", (unsigned long long)puts, (unsigned long long)gen);
    }
    printf("%s t_nvn_ghost_sub：%u 项，%u 项失败\n", fails ? "✗" : "✓", checks, fails);
    return fails != 0;
} }
