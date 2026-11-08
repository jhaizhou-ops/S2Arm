// 通用层资源表扩容失败（11-01 审计 P1-44）：六张表（贴图 / 缓冲 / 命令段 / 临时内存块 / 深度模板缓存 / 计算管线缓存）扩表时 realloc 失败，
//   不许往「空指针 + 偏移」写、不许先改容量，旧表照用，这次按建失败（或不进缓存 / 不分段）处理；失败过后放开分配，下一次照常扩表、编号接着排。
// 测试替身：本单测自带 realloc 强定义（同一次链接里盖过 libSystem 的，只影响直连进本可执行文件的渲染器源码，系统框架照用原版），
//   武装后下一次「新大小 ≥ g_min（或 == g_exact）」的 realloc 返回 NULL 并计一次命中（命中 1 次 = 被测扩表路径真跑到了）。
// 旧做法（先改容量、p = realloc(p, …)、再清零 / 写入）在任一用例里都会段错误（信号处理打栈后以 128+信号退出）= 红。
// 期望值手算：贴图 / 缓冲编号就是表下标、初始容量 1024、按 2 倍扩（gal_tex.m / gal_buf.m 表的设计），扩表失败那次返回 0，放开后返回本该拿到的下一号；
//   命令段表初始 256 项、每项一个指针，第一次分段即首次扩表（2048 字节）。用法：t_grow [tex|buf|seg|tr|dss|cpso]（不给 = 全跑）
#import "../gal_internal.h"
#import "../gal_draw_internal.h"
#include <malloc/malloc.h>
#include <execinfo.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
GAL_MTL4_ZONE_BEGIN

static size_t g_min, g_exact; static int g_hits;
void *realloc(void *p, size_t n) {
    if ((g_min && n >= g_min) || (g_exact && n == g_exact)) { g_min = g_exact = 0; g_hits++; return NULL; }
    return malloc_zone_realloc(malloc_default_zone(), p, n);
}
static void arm_min(size_t n) { g_hits = 0; g_exact = 0; g_min = n; }
static void arm_exact(size_t n) { g_hits = 0; g_min = 0; g_exact = n; }
static void disarm(void) { g_min = g_exact = 0; }

static void on_sig(int s) { void *b[32]; int n = backtrace(b, 32); backtrace_symbols_fd(b, n, 2); _exit(128 + s); }
static int g_fail, g_checks;
#define CHECK(cond, ...) do { g_checks++; if (!(cond)) { g_fail++; printf("  ✗ " __VA_ARGS__); printf("\n"); } else { printf("  ✓ " __VA_ARGS__); printf("\n"); } } while (0)

static nxgal_tex_info ti1(void) { return (nxgal_tex_info){1, 1, 1, 1, 1, 1, 1, 4, 36, 0, 1, {2, 3, 4, 5}}; }
extern uint64_t g_seg_n[2];
extern int gal_prepass_test_any;

static void t_tex(void) {
    printf("· 贴图表：1023 号之后扩到 2048 项失败 → 建贴图返回 0，1023 号照旧有效；放开后下一张拿 1024 号\n");
    nxgal_tex_info i = ti1(); uint32_t id = 0;
    for (int k = 0; k < 4096 && id != 1023; k++) id = nxgal_tex_create(&i);
    CHECK(id == 1023, "建到 1023 号（实际最后一号 %u）", id); if (id != 1023) return;
    arm_exact((size_t)2048 * sizeof(gal_tex));
    uint32_t bad = nxgal_tex_create(&i); disarm();
    CHECK(g_hits == 1, "扩表 realloc 真走到并失败 1 次（%d）", g_hits);
    CHECK(bad == 0, "扩表失败时返回 0（%u）", bad);
    gal_tex *t = gal_tex_get(1023);
    CHECK(t && t->tex && t->info.width == 1, "旧表 1023 号仍有效");
    uint32_t next = nxgal_tex_create(&i);
    CHECK(next == 1024, "放开后下一张是 1024 号（%u）", next);
    CHECK(gal_tex_get(1024) && gal_tex_get(1023), "扩表后 1023 / 1024 号都可取");
}

static void t_buf(void) {
    printf("· 缓冲表：1023 号之后扩表失败 → 建缓冲返回 0，1023 号大小照旧；放开后下一个拿 1024 号\n");
    uint32_t id = 0;
    for (int k = 0; k < 4096 && id != 1023; k++) id = nxgal_buf_create(16, 0);
    CHECK(id == 1023, "建到 1023 号（实际最后一号 %u）", id); if (id != 1023) return;
    arm_min(16 << 10);   // 2048 项 × 每项至少 8 字节
    uint32_t bad = nxgal_buf_create(16, 0); disarm();
    CHECK(g_hits == 1, "扩表 realloc 真走到并失败 1 次（%d）", g_hits);
    CHECK(bad == 0, "扩表失败时返回 0（%u）", bad);
    CHECK(gal_buf_size(1023) == 16, "旧表 1023 号大小仍是 16（%d）", gal_buf_size(1023));
    uint32_t next = nxgal_buf_create(24, 0);
    CHECK(next == 1024 && gal_buf_size(1024) == 24, "放开后下一个是 1024 号、大小 24（%u，%d）", next, gal_buf_size(next));
    CHECK(gal_buf_size(1023) == 16, "扩表后 1023 号大小仍是 16");
}

static MTL4RenderPassDescriptor *rp(id<MTLTexture> t) {
    MTL4RenderPassDescriptor *d = [MTL4RenderPassDescriptor new];
    d.colorAttachments[0].texture = t; d.colorAttachments[0].loadAction = MTLLoadActionClear; d.colorAttachments[0].storeAction = MTLStoreActionStore;
    d.renderTargetWidth = t.width; d.renderTargetHeight = t.height; return d;
}
static void t_seg(void) {
    printf("· 命令段表：第一次分段要扩到 256 项，失败 → 这一遍不分段（记「账本不给」），不崩；放开后下一遍照常分段\n");
    nxgal_tex_info i = ti1(); i.width = i.height = 8; uint32_t tid = nxgal_tex_create(&i); id<MTLTexture> t = gal_tex_get(tid)->tex;
    gal_prepass_test_any = 1; gal_prepass_want();
    gal_render_begin_desc(rp(t)); gal_enc_end();   // 第一遍：命令缓冲里有活了
    uint64_t s0 = g_seg_n[0], n0 = g_seg_n[1];
    arm_exact(256 * sizeof(void *));
    gal_render_begin_desc(rp(t)); gal_enc_end(); disarm();
    CHECK(g_hits == 1, "段表扩表 realloc 真走到并失败 1 次（%d）", g_hits);
    CHECK(g_seg_n[0] == s0 && g_seg_n[1] == n0 + 1, "失败那遍没分段、记一次不给（开成 +%llu，不给 +%llu）", g_seg_n[0] - s0, g_seg_n[1] - n0);
    gal_prepass_want();
    gal_render_begin_desc(rp(t)); gal_enc_end();
    CHECK(g_seg_n[0] == s0 + 1, "放开后下一遍分段（开成 +%llu）", g_seg_n[0] - s0);
    gal_commit(); gal_prepass_test_any = 0; nxgal_tex_release(tid);
}

static void t_tr(void) {
    printf("· 临时内存块表：要新建一块时扩表失败 → 返回 NULL、地址 0；放开后同样请求拿到可写内存\n");
    uint64_t gpu = 1;
    arm_min(1);
    void *p = gal_transient(64u << 20, 16, &gpu); disarm();   // 大于常规块：一定新建块
    CHECK(g_hits == 1, "块表扩表 realloc 真走到并失败 1 次（%d）", g_hits);
    CHECK(p == NULL && gpu == 0, "扩表失败返回 NULL、地址 0（%p，%llu）", p, gpu);
    void *q = gal_transient(64u << 20, 16, &gpu);
    CHECK(q && gpu, "放开后拿到内存（%p）", q); if (q) { memset(q, 0x5a, 64u << 20); }
    gal_commit();
}

static void t_dss(void) {
    printf("· 深度模板缓存：扩表失败 → 照样返回建好的状态、不进缓存；放开后再取进缓存（第二、三次取同一对象）\n");
    arm_min(1);
    id a = gal_dss_get(1, 0); disarm();
    CHECK(g_hits == 1, "缓存扩表 realloc 真走到并失败 1 次（%d）", g_hits);
    CHECK(a != nil, "失败时仍返回深度模板状态");
    id b = gal_dss_get(1, 0), c = gal_dss_get(1, 0);
    CHECK(b != nil && b == c, "放开后进缓存：第二、三次是同一对象");
}

static void t_cpso(void) {
    printf("· 计算管线缓存：扩表失败 → 照样返回建好的管线、不进缓存；放开后再取进缓存（第二、三次取同一对象）\n");
    NSError *e = nil; id<MTLLibrary> lib = gal_helper_lib(GH_RESTRIDE, &e);
    CHECK(lib != nil, "取到辅助库"); if (!lib) return;
    id fn = gal_be_fn_desc(lib, @"restride");   // 渲染器自己的顶点重排核（gal_draw.m）
    arm_min(1);
    id p = gal_fn_compute_pso(fn, 0x7a11a5e0deadull); disarm();
    CHECK(g_hits == 1, "缓存扩表 realloc 真走到并失败 1 次（%d）", g_hits);
    CHECK(p != nil, "失败时仍返回建好的计算管线");
    id q = gal_fn_compute_pso(fn, 0x7a11a5e0deadull), r = gal_fn_compute_pso(fn, 0x7a11a5e0deadull);
    CHECK(q != nil && q == r, "放开后进缓存：第二、三次是同一对象");
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    signal(SIGSEGV, on_sig); signal(SIGBUS, on_sig);
    if (nxgal_init(0)) return 2;
    const char *only = argc > 1 ? argv[1] : NULL;
#define RUN(n) if (!only || !strcmp(only, #n)) t_##n()
    RUN(tex); RUN(buf); RUN(seg); RUN(tr); RUN(dss); RUN(cpso);
    printf("%d / %d checks passed\n", g_checks - g_fail, g_checks);
    return g_fail ? 1 : 0;
}
GAL_MTL4_ZONE_END
