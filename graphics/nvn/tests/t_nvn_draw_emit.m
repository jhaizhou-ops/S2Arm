// 直连绘制的落地调用（nvn_mtl.m draw_emit）：直接包含生产 nvn_mtl.m，真 Metal 4 设备 + 真暂存区（arena），只把渲染编码器换成记录调用的假对象。
// 期望按 NVN / GL 的图元规则手算，不由被测实现推出：
//   ① 非间接四边形 / 扇形超过共享索引缓冲（SHARED_IB_N = 65536 个四边形 / 扇形三角形，审计 #846 F-nvn-shared-ib）：
//      交给 Metal 的索引数 × 4 不超过所给索引缓冲长度，且索引内容 = 四边形 (4q, 4q+1, 4q+2, 4q, 4q+2, 4q+3) / 扇形 (0, t+1, t+2)，基顶点 = first
//      四边形 count = 4 × 65536 + 8 → 65538 个四边形 393228 个索引；扇形 count = 65540 → 65538 个三角形 196614 个索引
//   反证：改前直接按 count 算索引数、索引缓冲仍是 65536 个图元那块，索引数 × 4 超过长度
//   ② 非间接索引绘制按 NVN 图元重启（SetPrimitiveRestart，重启值按索引宽度截，同 tf_draw；审计 #846 F-nvn-restart-raw）：
//      Metal 条带只在该宽度全 1 处断、别处不断；扇形 / 四边形是 CPU 展开，重启处开新的一段（不足一个图元的尾巴丢掉）
//      A 16 位扇形 开重启 0xFFFF {0,1,2,3,FFFF,10,11,12} → (0,1,2)(0,2,3)(10,11,12)
//      B 16 位四边形 开重启 0xFFFF {0,1,2,3,4,5,FFFF,8,9,10,11} → (0,1,2)(0,2,3)(8,9,10)(8,10,11)（{4,5} 不足一个四边形）
//      C 16 位三角带 关重启 {0,1,2,FFFF,3} → 32 位 {0,1,2,0xFFFF,3}（0xFFFF 是顶点 65535，不能让 Metal 断）
//      D 16 位三角带 开重启 0x1234 {0,1,2,1234,3,4,5} → 32 位 {0,1,2,FFFFFFFF,3,4,5}
//      E / F 16 位三角带 开重启 0xFFFF / −1（截成 0xFFFF）：Metal 原生，原样 16 位、直接用客人索引缓冲
//      G 8 位线带 开重启 0xFF {0,1,FF,2,3} → 16 位 {0,1,FFFF,2,3}
//      H 32 位线带 开重启 0x1234 {0,1,1234,2} → {0,1,FFFFFFFF,2}
//   反证：改前扇形 / 四边形把重启值当顶点展开、条带原样交给 Metal
#include "../gfx/nvn/nvn_mtl.m"

static unsigned failures, checks;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "FAIL setup %s:%d: %s\n", __FILE__, __LINE__, #c); exit(1); } } while (0)
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) failures++; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)

// 假渲染编码器：只记最后一次索引绘制的参数
@interface FakeEnc : NSObject { @public int calls; MTLPrimitiveType p; NSUInteger n, len, inst, bi; MTLIndexType t; uint64_t gpu; NSInteger bv; } @end
@implementation FakeEnc
- (void)drawIndexedPrimitives:(MTLPrimitiveType)p_ indexCount:(NSUInteger)n_ indexType:(MTLIndexType)t_ indexBuffer:(uint64_t)g_ indexBufferLength:(NSUInteger)l_
                instanceCount:(NSUInteger)i_ baseVertex:(NSInteger)bv_ baseInstance:(NSUInteger)bi_ { calls++; p = p_; n = n_; t = t_; gpu = g_; len = l_; inst = i_; bv = bv_; bi = bi_; }
- (void)drawPrimitives:(MTLPrimitiveType)p_ vertexStart:(NSUInteger)v vertexCount:(NSUInteger)c { calls++; p = p_; n = c; gpu = 0; }
@end

// 索引缓冲 GPU 地址 → CPU 指针（共享索引缓冲、本次提交的暂存区或客人内存池；都是共享存储）
static const uint8_t *cpu_of(uint64_t gpu, uint64_t len) {
    if (g_quad_ib && gpu >= g_quad_gpu && gpu + len <= g_quad_gpu + g_quad_ib.length) return (const uint8_t *)g_quad_ib.contents + (gpu - g_quad_gpu);
    if (g_fan_ib && gpu >= g_fan_gpu && gpu + len <= g_fan_gpu + g_fan_ib.length) return (const uint8_t *)g_fan_ib.contents + (gpu - g_fan_gpu);
    for (NvArena *a in g_sub_arenas) if (gpu >= a->gpu && gpu + len <= a->gpu + a->buf.length) return (const uint8_t *)a->buf.contents + (gpu - a->gpu);
    for (int i = 0; i < g_npool; i++) if (gpu >= g_pools[i].gpu && gpu + len <= g_pools[i].gpu + g_pools[i].buf.length) return (const uint8_t *)g_pools[i].buf.contents + (gpu - g_pools[i].gpu);   // 客人内存池（零拷贝）
    return NULL;
}
static int cpu_arena(uint64_t gpu) { for (NvArena *a in g_sub_arenas) if (gpu >= a->gpu && gpu < a->gpu + a->buf.length) return 1; return 0; }
static int fake_ok(FakeEnc *f) { return f->calls == 1 && f->t == MTLIndexTypeUInt32 && (uint64_t)f->n * 4 <= f->len; }

static void shared_ib(void) {
    enum { NQ = 65536 + 2, FIRST = 100 };
    FakeEnc *f = [FakeEnc new];
    p_draw q = {.prim = 7, .first = FIRST, .count = 4 * NQ, .instances = 1};
    draw_emit(f, MTLPrimitiveTypeTriangle, 7, &q, NULL, 0);
    VERIFY(fake_ok(f) && f->n == (NSUInteger)NQ * 6, "① 四边形 count %d：期望 1 次 32 位索引绘制、%u 个索引、索引数 × 4 ≤ 缓冲长度，实得 %d 次、%lu 个、长度 %lu 字节",
           4 * NQ, NQ * 6, f->calls, (unsigned long)f->n, (unsigned long)f->len);
    const uint32_t *ix = fake_ok(f) ? (const uint32_t *)cpu_of(f->gpu, (uint64_t)f->n * 4) : NULL; unsigned bad = 0;
    for (uint32_t k = 0; ix && k < NQ; k++) { uint32_t b = 4 * k, w[6] = {b, b + 1, b + 2, b, b + 2, b + 3}; bad += memcmp(ix + 6 * k, w, 24) != 0; }
    VERIFY(ix && !bad && f->bv == FIRST, "① 四边形索引 = (4q, 4q+1, 4q+2, 4q, 4q+2, 4q+3)、基顶点 %d：错 %u 个四边形、基顶点 %ld%s", FIRST, bad, (long)f->bv, ix ? "" : "（索引不在可读缓冲里）");
    enum { NF = 65536 + 4 };
    f = [FakeEnc new];
    p_draw fan = {.prim = 6, .first = FIRST, .count = NF, .instances = 2, .base_instance = 3};
    draw_emit(f, MTLPrimitiveTypeTriangle, 6, &fan, NULL, 0);
    VERIFY(fake_ok(f) && f->n == (NSUInteger)(NF - 2) * 3 && f->inst == 2 && f->bi == 3, "① 扇形 count %d：期望 %u 个索引、索引数 × 4 ≤ 缓冲长度、实例 2 / 基实例 3，实得 %d 次、%lu 个、长度 %lu、实例 %lu / %lu",
           NF, (NF - 2) * 3, f->calls, (unsigned long)f->n, (unsigned long)f->len, (unsigned long)f->inst, (unsigned long)f->bi);
    ix = fake_ok(f) ? (const uint32_t *)cpu_of(f->gpu, (uint64_t)f->n * 4) : NULL; bad = 0;
    for (uint32_t k = 0; ix && k < NF - 2; k++) bad += ix[3 * k] != 0 || ix[3 * k + 1] != k + 1 || ix[3 * k + 2] != k + 2;
    VERIFY(ix && !bad && f->bv == FIRST, "① 扇形索引 = (0, t+1, t+2)、基顶点 %d：错 %u 个三角形%s", FIRST, bad, ix ? "" : "（索引不在可读缓冲里）");
    f = [FakeEnc new];
    p_draw small = {.prim = 7, .first = 0, .count = 8, .instances = 1};
    draw_emit(f, MTLPrimitiveTypeTriangle, 7, &small, NULL, 0);
    VERIFY(f->calls == 1 && f->n == 12 && f->gpu == g_quad_gpu, "① 小四边形（2 个）仍走共享索引缓冲：12 个索引，实得 %lu 个、%s", (unsigned long)f->n, f->gpu == g_quad_gpu ? "共享" : "非共享");
}

static uint8_t *g_mem;   // 客人索引（登记成内存池）
static FakeEnc *idx_draw(int prim, int itype, const void *ix, int n, int on, uint32_t rv) {
    static size_t at; size_t isz = itype == 0 ? 1 : itype == 1 ? 2 : 4; at = (at + 255) & ~(size_t)255; memcpy(g_mem + at, ix, (size_t)n * isz);
    S.restart = (p_prim_restart){(uint32_t)on, rv};
    p_draw_idx d = {.prim = prim, .itype = itype, .count = n, .instances = 1, .ibuf = (uint64_t)(uintptr_t)(g_mem + at)};
    FakeEnc *f = [FakeEnc new]; draw_emit(f, prim == 3 ? MTLPrimitiveTypeLineStrip : prim == 5 ? MTLPrimitiveTypeTriangleStrip : MTLPrimitiveTypeTriangle, prim, NULL, &d, 0);
    at += (size_t)n * isz; return f;
}
// 实际交给 Metal 的索引与期望逐个比（期望按 32 位写；16 位绘制按 16 位读）
static int same(FakeEnc *f, MTLIndexType t, const uint32_t *want, int n) {
    if (f->calls != 1 || f->t != t || f->n != (NSUInteger)n) return 0;
    const uint8_t *p = cpu_of(f->gpu, (uint64_t)n * (t == MTLIndexTypeUInt16 ? 2 : 4)); if (!p) return 0;
    for (int i = 0; i < n; i++) if ((t == MTLIndexTypeUInt16 ? ((const uint16_t *)p)[i] : ((const uint32_t *)p)[i]) != want[i]) return 0;
    return 1;
}
static void restart(void) {
    REQUIRE(!posix_memalign((void **)&g_mem, 16384, 1 << 16)); memset(g_mem, 0, 1 << 16); nvn_be_pool_add(g_mem, 1 << 16);
    { uint16_t ix[] = {0, 1, 2, 3, 0xFFFF, 10, 11, 12}; uint32_t w[] = {0, 1, 2, 0, 2, 3, 10, 11, 12};
      FakeEnc *f = idx_draw(6, 1, ix, 8, 1, 0xFFFF); VERIFY(same(f, MTLIndexTypeUInt32, w, 9), "② A 16 位扇形开重启：期望 9 个索引 (0,1,2)(0,2,3)(10,11,12)，实得 %lu 个", (unsigned long)f->n); }
    { uint16_t ix[] = {0, 1, 2, 3, 4, 5, 0xFFFF, 8, 9, 10, 11}; uint32_t w[] = {0, 1, 2, 0, 2, 3, 8, 9, 10, 8, 10, 11};
      FakeEnc *f = idx_draw(7, 1, ix, 11, 1, 0xFFFF); VERIFY(same(f, MTLIndexTypeUInt32, w, 12), "② B 16 位四边形开重启：期望 12 个索引（{4,5} 丢掉），实得 %lu 个", (unsigned long)f->n); }
    { uint16_t ix[] = {0, 1, 2, 0xFFFF, 3}; uint32_t w[] = {0, 1, 2, 0xFFFF, 3};
      FakeEnc *f = idx_draw(5, 1, ix, 5, 0, 0xFFFF); VERIFY(same(f, MTLIndexTypeUInt32, w, 5), "② C 16 位三角带关重启、索引里有 0xFFFF：期望零扩成 32 位，实得类型 %lu、%lu 个", (unsigned long)f->t, (unsigned long)f->n); }
    { uint16_t ix[] = {0, 1, 2, 0x1234, 3, 4, 5}; uint32_t w[] = {0, 1, 2, 0xFFFFFFFF, 3, 4, 5};
      FakeEnc *f = idx_draw(5, 1, ix, 7, 1, 0x1234); VERIFY(same(f, MTLIndexTypeUInt32, w, 7), "② D 16 位三角带开重启 0x1234：期望 32 位、0x1234 → 0xFFFFFFFF，实得类型 %lu、%lu 个", (unsigned long)f->t, (unsigned long)f->n); }
    { uint16_t ix[] = {0, 1, 2, 0xFFFF, 3, 4, 5}; uint32_t w[] = {0, 1, 2, 0xFFFF, 3, 4, 5};
      FakeEnc *f = idx_draw(5, 1, ix, 7, 1, 0xFFFF); uint64_t g0 = f->gpu;
      VERIFY(same(f, MTLIndexTypeUInt16, w, 7) && !cpu_arena(g0), "② E 16 位三角带开重启 0xFFFF：期望原样 16 位、用客人缓冲（不进暂存区）");
      f = idx_draw(5, 1, ix, 7, 1, 0xFFFFFFFF); VERIFY(same(f, MTLIndexTypeUInt16, w, 7) && !cpu_arena(f->gpu), "② F 16 位三角带开重启 −1（截成 0xFFFF）：期望原样 16 位"); }
    { uint8_t ix[] = {0, 1, 0xFF, 2, 3}; uint32_t w[] = {0, 1, 0xFFFF, 2, 3};
      FakeEnc *f = idx_draw(3, 0, ix, 5, 1, 0xFF); VERIFY(same(f, MTLIndexTypeUInt16, w, 5), "② G 8 位线带开重启 0xFF：期望加宽后重启值成 0xFFFF"); }
    { uint32_t ix[] = {0, 1, 0x1234, 2}; uint32_t w[] = {0, 1, 0xFFFFFFFF, 2};
      FakeEnc *f = idx_draw(3, 2, ix, 4, 1, 0x1234); VERIFY(same(f, MTLIndexTypeUInt32, w, 4), "② H 32 位线带开重启 0x1234：期望 0x1234 → 0xFFFFFFFF"); }
    S.restart = (p_prim_restart){0, 0};
}

int main(void) {
    @autoreleasepool {
        alarm(120);
        setenv("DM_PRESENT_LINK", "0", 1); unsetenv("NXGAL_BE");
        mtl_init();
        REQUIRE(!g_m3);
        nvn_be_sub_begin();
        shared_ib();
        restart();
        nvn_be_drain();
    }
    if (failures) { printf("✗ t_nvn_draw_emit：%u / %u 项不过\n", failures, checks); return 1; }
    printf("✓ t_nvn_draw_emit：%u 项全过（共享索引缓冲覆盖、图元重启）\n", checks);
    return 0;
}
