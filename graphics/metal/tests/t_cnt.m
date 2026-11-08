// 计数单测（gal_cnt.m）：自带最小管线画像素对齐的矩形（像素中心严格在内的数 = 宽 × 高），SamplesPassed 期望 = 像素数 × 采样数，全部手算。
// 本文件按 Objective-C 编（Makefile 用 -x objective-c），与后端源码静态链接，直接用内部接口 gal_render_enc / gal_cnt_on_draw（绘制模块的调用约定）。
#import "../gal_internal.h"
#include "fixture.h"   // 固定 MSL 走离线 metallib 夹具（不是被测对象，不经运行时编译服务）
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <execinfo.h>
#include <signal.h>
#include <unistd.h>
#include <pthread.h>
GAL_MTL4_ZONE_BEGIN   // Metal 4 可用性区（gal_internal.h）
static void on_sig(int s) { void *b[32]; int n = backtrace(b, 32); backtrace_symbols_fd(b, n, 2); _exit(128 + s); }

static int g_fail, g_checks;
#define CHECK(cond, ...) do { g_checks++; if (!(cond)) { g_fail++; printf("  ✗ " __VA_ARGS__); printf("\n"); } } while (0)
enum { SP = 0, PG = 1, XFB = 2 };
enum { R8G8B8A8Unorm = 36 };

// ---------- 最小管线：矩形（三角带 4 顶点），可选全丢弃 ----------
static NSString *const k_msl = @
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"struct P { float4 rect; float4 color; uint kill; };\n"
"struct V { float4 pos [[position]]; };\n"
"vertex V t_vs(uint vid [[vertex_id]], constant P &p [[buffer(0)]]) {\n"
"  V o; o.pos = float4((vid & 1) ? p.rect.z : p.rect.x, (vid & 2) ? p.rect.w : p.rect.y, 0.0, 1.0); return o; }\n"
"fragment float4 t_fs(V in [[stage_in]], constant P &p [[buffer(0)]]) { if (p.kill) discard_fragment(); return p.color; }\n";
typedef struct { float rect[4]; float color[4]; uint32_t kill; uint32_t pad[3]; } t_params;
static id<MTLLibrary> g_lib; static id<MTL4ArgumentTable> g_vt, g_ft; static id<MTLDepthStencilState> g_dss;
static id<MTLRenderPipelineState> g_pso[2];   // [0] 1 采样 [1] 4 采样（RGBA8）

static MTL4LibraryFunctionDescriptor *fnd(NSString *n) { MTL4LibraryFunctionDescriptor *f = [MTL4LibraryFunctionDescriptor new]; f.library = g_lib; f.name = n; return f; }
static int t_init(void) {
    NSError *e = nil;
    g_lib = fx_lib(g_gdev, @"t_cnt", k_msl, &e); if (!g_lib) { printf("编着色器失败：%s\n", e.localizedDescription.UTF8String); return 0; }
    MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new]; ad.maxBufferBindCount = 1;
    g_vt = [g_gdev newArgumentTableWithDescriptor:ad error:&e]; g_ft = [g_gdev newArgumentTableWithDescriptor:ad error:&e];
    for (int i = 0; i < 2; i++) {
        MTL4RenderPipelineDescriptor *d = [MTL4RenderPipelineDescriptor new];
        d.vertexFunctionDescriptor = fnd(@"t_vs"); d.fragmentFunctionDescriptor = fnd(@"t_fs");
        d.rasterSampleCount = i ? 4 : 1; d.inputPrimitiveTopology = MTLPrimitiveTopologyClassTriangle;
        d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        g_pso[i] = [g_gcomp newRenderPipelineStateWithDescriptor:d compilerTaskOptions:nil error:&e];
        if (!g_pso[i]) { printf("编管线失败：%s\n", e.localizedDescription.UTF8String); return 0; }
    }
    MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new]; dd.depthCompareFunction = MTLCompareFunctionAlways; dd.depthWriteEnabled = NO;
    g_dss = [g_gdev newDepthStencilStateWithDescriptor:dd];
    return 1;
}
static int g_W, g_H, g_ms;   // 当前目标尺寸与是否 4 采样
// 像素矩形 (x, y, w, h) → NDC（y 向上）；边全在整数像素线上，覆盖像素数 = w × h
static void draw_rect(int x, int y, int w, int h, int kill) {
    id<MTL4RenderCommandEncoder> e = gal_render_enc();
    uint64_t gpu; t_params *p = gal_transient(sizeof *p, 16, &gpu); memset(p, 0, sizeof *p);
    p->rect[0] = 2.0f * x / g_W - 1; p->rect[2] = 2.0f * (x + w) / g_W - 1;
    p->rect[1] = 1 - 2.0f * (y + h) / g_H; p->rect[3] = 1 - 2.0f * y / g_H;
    p->color[0] = 1; p->color[3] = 1; p->kill = (uint32_t)kill;
    [g_vt setAddress:gpu atIndex:0]; [g_ft setAddress:gpu atIndex:0];
    [e setArgumentTable:g_vt atStages:MTLRenderStageVertex]; [e setArgumentTable:g_ft atStages:MTLRenderStageFragment];
    [e setRenderPipelineState:g_pso[g_ms]]; [e setDepthStencilState:g_dss];
    [e setViewport:(MTLViewport){0, 0, g_W, g_H, 0, 1}]; [e setScissorRect:(MTLScissorRect){0, 0, (NSUInteger)g_W, (NSUInteger)g_H}];
    [e setCullMode:MTLCullModeNone];
    gal_cnt_on_draw(e);
    [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
}
static uint32_t make_rt(int w, int h, int samples) {
    nxgal_tex_info i = {w, h, 1, 1, samples, 1, 1, 4, R8G8B8A8Unorm, 0, samples > 1 ? 5 : 1, {2, 3, 4, 5}};
    uint32_t t = nxgal_tex_create(&i);
    nxgal_set_render_targets(&t, 1, 0);
    g_W = w; g_H = h; g_ms = samples > 1;
    return t;
}

// ---------- 结果收集：poll 出来的按事件号记下（顺序也记） ----------
#define MAXEV 8192
static uint64_t g_val[MAXEV + 1]; static uint8_t g_got[MAXEV + 1]; static uint32_t g_order[MAXEV * 2]; static int g_norder;
static void poll_all(void) {
    uint32_t ids[64]; uint64_t v[64]; int n;
    while ((n = nxgal_counter_poll(ids, v, 64)) > 0)
        for (int i = 0; i < n; i++) { if (ids[i] <= MAXEV) { g_got[ids[i]]++; g_val[ids[i]] = v[i]; } g_order[g_norder++ % (MAXEV * 2)] = ids[i]; }
}
static long long val_after_flush(uint32_t ev) { nxgal_counter_flush(ev); poll_all(); return g_got[ev] ? (long long)g_val[ev] : -1; }

static void t_basic(void) {
    printf("· 64×32 单采样：Reset → 画 16×8 → Report = 128；无绘制再 Report = 累计 128 且不等 GPU 即出\n");
    nxgal_counter_reset(SP);
    draw_rect(8, 4, 16, 8, 0);
    uint32_t a = nxgal_counter_report(SP, 1, 0);
    long long v = val_after_flush(a); CHECK(v == 128, "期望 128 实得 %lld", v);
    uint32_t b = nxgal_counter_report(SP, 1, 0);
    poll_all(); CHECK(g_got[b] == 1 && g_val[b] == 128, "无绘制区间：期望 poll 直接出 128，实得 got=%d val=%llu", g_got[b], (unsigned long long)g_val[b]);
}
static void t_passes(uint32_t rt_small) {
    printf("· 同一区间跨两个通道（屏障拆通道）+ 换渲染目标：2048 + 128 + 32×32 全屏 1024 → 累计 128+3200 = 3328\n");
    draw_rect(0, 0, 64, 32, 0);
    // 结束渲染编码器 → 下次绘制开新通道。不用 nxgal_barrier：遍里没有存储写的内存屏障不再拆遍（gal_pass.m gal_pass_membar_split），
    // 屏障与可见性计数本来无关（Ryujinx 计数语义只认 Reset / Report 区间），这里要的只是「同一区间跨两个通道」
    gal_pass_close();
    draw_rect(40, 20, 16, 8, 0);
    uint32_t keep = rt_small;
    nxgal_set_render_targets(&keep, 1, 0); g_W = 32; g_H = 32; g_ms = 0;
    draw_rect(0, 0, 32, 32, 0);
    uint32_t e = nxgal_counter_report(SP, 1, 0);
    long long v = val_after_flush(e); CHECK(v == 3328, "期望 3328 实得 %lld", v);
}
static void t_commits(void) {
    printf("· 同一区间跨三次提交：10×10 | flush | 10×10 | flush | 1×1 → 累计 3328+201 = 3529；最后一段未提交前 poll 不出\n");
    draw_rect(0, 0, 10, 10, 0); nxgal_flush();
    draw_rect(5, 5, 10, 10, 0); nxgal_flush();
    draw_rect(31, 31, 1, 1, 0);
    uint32_t e = nxgal_counter_report(SP, 1, 0);
    poll_all(); CHECK(!g_got[e], "在录命令还没提交，结果不应已出");
    long long v = val_after_flush(e); CHECK(v == 3529, "期望 3529 实得 %lld", v);
}
static void t_switch_in_encoder(void) {
    printf("· 同一编码器内换区间：4×4 → Report A → 2×2 → Report B；A = 3545、B = 3549，按序出\n");
    draw_rect(0, 0, 4, 4, 0);
    uint32_t a = nxgal_counter_report(SP, 1, 0);
    draw_rect(8, 8, 2, 2, 0);
    uint32_t b = nxgal_counter_report(SP, 1, 0);
    int o0 = g_norder;
    long long vb = val_after_flush(b);
    CHECK(g_got[a] && g_val[a] == 3545, "A 期望 3545 实得 %llu（got %d）", (unsigned long long)g_val[a], g_got[a]);
    CHECK(vb == 3549, "B 期望 3549 实得 %lld", vb);
    CHECK(g_norder - o0 == 2 && g_order[o0] == a && g_order[o0 + 1] == b, "出结果顺序应为 A、B");
}
static void t_reset(void) {
    printf("· Reset 清零：Reset → 3×5 → Report = 15；区间内先画 2048 再 Reset 再画 2×3 → Report = 6（Reset 前的样本作废）\n");
    nxgal_counter_reset(SP); draw_rect(1, 1, 3, 5, 0);
    long long v = val_after_flush(nxgal_counter_report(SP, 1, 0)); CHECK(v == 15, "期望 15 实得 %lld", v);
    draw_rect(0, 0, 32, 32, 0); nxgal_counter_reset(SP); draw_rect(0, 0, 2, 3, 0);
    v = val_after_flush(nxgal_counter_report(SP, 1, 0)); CHECK(v == 6, "期望 6 实得 %lld", v);
}
static void t_divisor(void) {
    printf("· divisor：Reset → 3×1 /2 → ceil(1.5)=2；再 3×1 /2 → 2+2 = 4；Reset → 32×32 /4 → 256\n");
    nxgal_counter_reset(SP); draw_rect(0, 0, 3, 1, 0);
    long long v = val_after_flush(nxgal_counter_report(SP, 2, 0)); CHECK(v == 2, "期望 2 实得 %lld", v);
    draw_rect(0, 1, 3, 1, 0);
    v = val_after_flush(nxgal_counter_report(SP, 2, 0)); CHECK(v == 4, "期望 4 实得 %lld", v);
    nxgal_counter_reset(SP); draw_rect(0, 0, 32, 32, 0);
    v = val_after_flush(nxgal_counter_report(SP, 4, 0)); CHECK(v == 256, "期望 256 实得 %lld", v);
}
static void t_aux_and_kill(void) {
    printf("· 不计样本：通道内局部清屏（辅助三角）0；2×2 + 局部清 + 2×2 = 8；片元全丢弃 0\n");
    nxgal_counter_reset(SP);
    draw_rect(0, 0, 1, 1, 0);   // 先开通道，让清屏走「通道内辅助三角」
    nxgal_counter_reset(SP);    // 上面这 1 个样本作废
    nxgal_rect sc = {4, 4, 8, 8}; nxgal_set_scissors(&sc, 1);
    float c[4] = {0, 1, 0, 1}; nxgal_clear_color(0, 0, 1, 0xf, c);
    long long v = val_after_flush(nxgal_counter_report(SP, 1, 0)); CHECK(v == 0, "局部清屏：期望 0 实得 %lld", v);
    nxgal_counter_reset(SP);
    draw_rect(0, 0, 2, 2, 0); nxgal_clear_color(0, 0, 1, 0xf, c); draw_rect(20, 20, 2, 2, 0);
    v = val_after_flush(nxgal_counter_report(SP, 1, 0)); CHECK(v == 8, "绘制夹清屏：期望 8 实得 %lld", v);
    nxgal_rect full = {0, 0, 0xffff, 0xffff}; nxgal_set_scissors(&full, 1);
    nxgal_counter_reset(SP); draw_rect(0, 0, 32, 32, 1);
    v = val_after_flush(nxgal_counter_report(SP, 1, 0)); CHECK(v == 0, "全丢弃：期望 0 实得 %lld", v);
}
// 一个计数区间里辅助绘制（通道内局部清屏）反复切开计数、几千个编码器 / 上百次提交都不取结果（马车8 菜单：区间几千帧不出结果、每帧一次局部清屏）。
// 期望值：每次绘制 1×1 单采样 = 1 个样本，清屏不计；旧代码每段取新槽、链只增不减，约 4095 段后槽用尽、之后每个编码器第二段不计 → 偏小
static void part_clear(void) {
    nxgal_rect sc = {4, 4, 8, 8}; nxgal_set_scissors(&sc, 1);
    float c[4] = {0, 0, 1, 1}; nxgal_clear_color(0, 0, 1, 0xf, c);
    nxgal_rect full = {0, 0, 0xffff, 0xffff}; nxgal_set_scissors(&full, 1);
}
static void t_aux_long_cross(void) {
    enum { N = 5000 };
    printf("· 跨通道：一个区间 %d 个编码器（显式收遍、每 64 个提交一次），每个编码器 1×1 + 局部清屏 + 1×1，不取结果 → 2×%d = %d\n", N, N, 2 * N);
    nxgal_counter_reset(SP);
    for (int k = 0; k < N; k++) {
        draw_rect(k % 32, (k / 32) % 32, 1, 1, 0); part_clear(); draw_rect((k + 7) % 32, 30, 1, 1, 0);
        gal_pass_close();
        if (k % 64 == 63) nxgal_flush();
    }
    long long v = val_after_flush(nxgal_counter_report(SP, 1, 0)); CHECK(v == 2 * N, "期望 %d 实得 %lld", 2 * N, v);
}
static void t_aux_long_single(void) {
    enum { N = 5000 };
    printf("· 不切通道：一个编码器里 %d 次（1×1 + 局部清屏）再 1×1，不取结果 → %d\n", N, N + 1);
    nxgal_counter_reset(SP);
    for (int k = 0; k < N; k++) { draw_rect(k % 32, (k / 32) % 32, 1, 1, 0); part_clear(); }
    draw_rect(31, 0, 1, 1, 0);
    long long v = val_after_flush(nxgal_counter_report(SP, 1, 0)); CHECK(v == N + 1, "期望 %d 实得 %lld", N + 1, v);
}
static void t_msaa(void) {
    printf("· 4 采样 16×16：Reset → 4×4 → 16 像素 × 4 采样 = 64\n");
    uint32_t t = make_rt(16, 16, 4);
    nxgal_counter_reset(SP); draw_rect(2, 2, 4, 4, 0);
    long long v = val_after_flush(nxgal_counter_report(SP, 1, 0)); CHECK(v == 64, "期望 64 实得 %lld", v);
    nxgal_set_render_targets(NULL, 0, 0); nxgal_tex_release(t);
}
static void t_release(void) {
    printf("· release：Reset → 5×5 → A（release）→ 1×1 → B；A 不回报、B = 26（A 的样本照常进累计）\n");
    nxgal_counter_reset(SP); draw_rect(0, 0, 5, 5, 0);
    uint32_t a = nxgal_counter_report(SP, 1, 0); nxgal_counter_release(a);
    draw_rect(9, 9, 1, 1, 0);
    uint32_t b = nxgal_counter_report(SP, 1, 0);
    long long v = val_after_flush(b);
    CHECK(!g_got[a], "A 已 release 不应回报");
    CHECK(v == 26, "B 期望 26 实得 %lld", v);
}
static void t_other_types(void) {
    printf("· PrimitivesGenerated / TransformFeedbackPrimitivesWritten：画了也恒 0，不等 GPU 即出；条件渲染恒走 CPU（返回 0）\n");
    nxgal_counter_reset(PG); draw_rect(0, 0, 4, 4, 0);
    uint32_t a = nxgal_counter_report(PG, 1, 0), b = nxgal_counter_report(XFB, 1, 0);
    poll_all();
    CHECK(g_got[a] && g_val[a] == 0, "PG 期望直接出 0");
    CHECK(g_got[b] && g_val[b] == 0, "XFB 期望直接出 0");
    CHECK(nxgal_cond_begin(a, 0, 0, 0) == 0, "cond_begin 应返回 0"); nxgal_cond_end();
}
static void t_many(void) {
    printf("· 5000 个区间不提交（超过 4096 槽，触发低水位排空）：第 k 个 = k，全部按序出\n");
    nxgal_counter_reset(SP);
    static uint32_t ev[5000];
    for (int k = 0; k < 5000; k++) { draw_rect(k % 32, (k / 32) % 32, 1, 1, 0); ev[k] = nxgal_counter_report(SP, 1, 0); }
    nxgal_counter_flush(ev[4999]); poll_all();
    int bad = 0;
    for (int k = 0; k < 5000; k++) if (ev[k] > MAXEV || !g_got[ev[k]] || g_val[ev[k]] != (uint64_t)k + 1) { if (bad++ < 3) printf("  ✗ 第 %d 个：got %d 值 %llu 期望 %d\n", k + 1, ev[k] <= MAXEV ? g_got[ev[k]] : -1, ev[k] <= MAXEV ? (unsigned long long)g_val[ev[k]] : 0ull, k + 1); }
    g_checks++; if (bad) { g_fail++; printf("  ✗ 共 %d / 5000 不符\n", bad); }
}

// ---------- 计数线程自己等结果（nxgal_counter_wait，照 Ryujinx CounterQueue.EventConsumer）----------
// 复现 10-22 八方2「出图停」：叫醒（UpdateCounters）时队头还在在录命令缓冲，之后只有提交、再没有叫醒——旧计数线程只在叫醒时取，结果永远不出。
// 这里起一条线程照 NxCounters.Consume 的样子循环「poll → wait」，主线程不再叫醒，看结果能不能自己到
static volatile int g_cw_stop; static volatile uint64_t g_cw_val[4]; static volatile uint32_t g_cw_id[4]; static volatile int g_cw_n;
static void *cw_main(void *arg) {
    (void)arg;
    while (!g_cw_stop) {
        uint32_t ids[64]; uint64_t v[64]; int n;
        while ((n = nxgal_counter_poll(ids, v, 64)) > 0)
            for (int i = 0; i < n; i++) { int k = g_cw_n; if (k < 4) { g_cw_id[k] = ids[i]; g_cw_val[k] = v[i]; __atomic_store_n(&g_cw_n, k + 1, __ATOMIC_RELEASE); } }
        nxgal_counter_wait(1000);
    }
    return NULL;
}
// 等计数线程收到 id（上限 ms）；收到返回值，否则 -1
static long long cw_await(uint32_t id, int ms) {
    for (int t = 0; t <= ms; t += 5) {
        for (int k = 0; k < __atomic_load_n(&g_cw_n, __ATOMIC_ACQUIRE); k++) if (g_cw_id[k] == id) return (long long)g_cw_val[k];
        usleep(5000);
    }
    return -1;
}
static void t_waiter(void) {
    printf("· 计数线程自己等结果：Reset → 画 8×8 → Report → 叫醒一次（还没提交）→ 提交、不再叫醒 → 500 ms 内收到 64；再无绘制 Report → 200 ms 内收到 64\n");
    uint32_t rt = make_rt(16, 16, 1);
    pthread_t th; g_cw_stop = 0; g_cw_n = 0;
    pthread_create(&th, NULL, cw_main, NULL);
    uint32_t e;
    { GAL_API_LOCK(); nxgal_counter_reset(SP); draw_rect(0, 0, 8, 8, 0); e = nxgal_counter_report(SP, 1, 0); }
    nxgal_counter_kick();
    usleep(50000);
    CHECK(cw_await(e, 0) < 0, "在录命令还没提交，计数线程不应已收到");
    nxgal_flush();
    long long v = cw_await(e, 500); CHECK(v == 64, "提交后不叫醒：期望 500 ms 内收到 64，实得 %lld（-1 = 没收到：计数线程没被提交叫醒）", v);
    uint32_t e2 = nxgal_counter_report(SP, 1, 0);
    long long v2 = cw_await(e2, 200); CHECK(v2 == 64, "无绘制 Report：期望 200 ms 内收到累计 64，实得 %lld", v2);
    g_cw_stop = 1; nxgal_counter_kick(); pthread_join(th, NULL);
    nxgal_tex_release(rt);
}

int main(void) {
    signal(SIGSEGV, on_sig); signal(SIGBUS, on_sig); signal(SIGABRT, on_sig);
    setvbuf(stdout, NULL, _IONBF, 0);
    if (nxgal_init(0)) { printf("初始化失败\n"); return 1; }
    if (!t_init()) return 1;
    uint32_t big = make_rt(64, 32, 1);
    nxgal_tex_info si = {32, 32, 1, 1, 1, 1, 1, 4, R8G8B8A8Unorm, 0, 1, {2, 3, 4, 5}};
    uint32_t small = nxgal_tex_create(&si);
    // 可见性结果缓冲建不出（注入 gal_newbuf_test_fail）：画 + Report → 不崩、按 0 出结果；撤注入后结束当前通道，下一项（t_basic）开新通道重建照常。
    // 旧代码反证：memset(nil.contents) 写空指针 SIGSEGV
    printf("· 可见性结果缓冲建不出（注入）：Reset → 画 16×8 → Report = 0（不计），不崩\n");
    gal_newbuf_test_fail = 1;
    nxgal_counter_reset(SP); draw_rect(8, 4, 16, 8, 0);
    { long long v = val_after_flush(nxgal_counter_report(SP, 1, 0)); CHECK(v == 0, "注入期间期望 0 实得 %lld", v); }
    gal_newbuf_test_fail = 0;
    // 收掉注入期间开的通道（它没挂上可见性缓冲），下一项开新通道重建。原先用 nxgal_barrier(0) 收：遍里没有存储写的内存屏障已不拆遍
    gal_pass_close();
    t_basic();
    t_passes(small);            // 之后目标 = small（32×32）
    t_commits();
    t_switch_in_encoder();
    t_reset();
    t_divisor();
    t_aux_and_kill();
    t_release();
    t_other_types();
    t_many();
    t_aux_long_cross();
    t_aux_long_single();
    t_msaa();
    t_waiter();
    nxgal_tex_release(big); nxgal_tex_release(small);
    nxgal_shutdown();
    printf("t_cnt：%d / %d 通过\n", g_checks - g_fail, g_checks);
    return g_fail ? 1 : 0;
}
GAL_MTL4_ZONE_END
