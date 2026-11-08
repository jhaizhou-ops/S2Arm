// 链接版顶不上时等管线不排在后台积压后面（gal_core.m gal_pso_job_wait，10-24 测试机1 xc3_1024150549_1 第 1259 帧渲染线程在这里等 10 秒以上：
//   作业交后台编译槽（2 条、UTILITY），每条现建另排一条收进设备归档的后台活，积压深时渲染线程要的那条迟迟轮不到）。
// 确定性：nxgal_test_bg_hold(1) 占住后台 2 个槽 → 作业一定排着、没开始编。
// 期望（手算）：
//   ① 槽占着时 gal_pso_job_wait 5 秒内返回管线、当场编计数 g_pso_wait_inline +1（认领下来在本线程编）；
//   ② 放开槽：排着的那个后台块轮到后看到已认领、直接放手，不再编一遍、不崩（等 1 秒后进程照常）；
//   ③ 另起一个作业、槽不占：后台照常编完，轮询取到管线，当场编计数不变（不抢后台已在编的）。
// 反证（旧写法：gal_pso_job_wait 只等信号量）：① 永不返回——本单测在另一条线程上等、5 秒超时判红，不会卡死门禁。
#import "../gal_internal.h"
#include "fixture.h"
#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
#include <stdatomic.h>
#include <unistd.h>
GAL_MTL4_ZONE_BEGIN
NXGAL_API void nxgal_test_bg_hold(int on);
extern uint64_t g_pso_wait_inline;
static int g_fail, g_checks;
#define CHECK(cond, ...) do { g_checks++; if (!(cond)) { g_fail++; printf("  ✗ " __VA_ARGS__); printf("\n"); } } while (0)

static NSString *const k_msl = @
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"struct V { float4 pos [[position]]; };\n"
"vertex V w_vs(uint vid [[vertex_id]]) { V o; o.pos = float4((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0, 0.0, 1.0); return o; }\n"
"fragment float4 w_fs(V in [[stage_in]]) { return float4(0.25, 0.5, 0.75, 1.0); }\n";
static id<MTLLibrary> g_lib;
static MTL4LibraryFunctionDescriptor *fnd(NSString *n) { MTL4LibraryFunctionDescriptor *f = [MTL4LibraryFunctionDescriptor new]; f.library = g_lib; f.name = n; return f; }
static MTL4RenderPipelineDescriptor *desc(MTLPixelFormat pf) {
    MTL4RenderPipelineDescriptor *d = [MTL4RenderPipelineDescriptor new];
    d.vertexFunctionDescriptor = fnd(@"w_vs"); d.fragmentFunctionDescriptor = fnd(@"w_fs");
    d.inputPrimitiveTopology = MTLPrimitiveTopologyClassTriangle; d.colorAttachments[0].pixelFormat = pf;
    return d;
}
static gal_pso_job *g_job; static id<MTLRenderPipelineState> g_got; static _Atomic int g_back;
static void *waiter(void *a) { (void)a; @autoreleasepool { g_got = gal_pso_job_wait(g_job); } atomic_store(&g_back, 1); return NULL; }

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    if (nxgal_init(0)) { printf("初始化失败\n"); return 2; }
    NSError *e = nil; g_lib = fx_lib(g_gdev, @"t_psowait", k_msl, &e); if (!g_lib) { printf("编着色器失败：%s\n", e.localizedDescription.UTF8String); return 2; }

    printf("· ① 后台槽占着：等管线 5 秒内期望返回、当场编 +1\n");
    nxgal_test_bg_hold(1);
    id<MTLRenderPipelineState> hit = nil; uint64_t in0 = g_pso_wait_inline;
    g_job = gal_new_render_pso_async(desc(MTLPixelFormatRGBA8Unorm), &hit);
    CHECK(g_job && !hit, "① 期望起了异步作业（没有归档可命中），实得 作业 %p 命中 %p", (void *)g_job, (__bridge void *)hit);
    pthread_t th; pthread_create(&th, NULL, waiter, NULL); pthread_detach(th);
    for (int i = 0; i < 500 && !atomic_load(&g_back); i++) usleep(10000);
    CHECK(atomic_load(&g_back) && g_got, "① 期望 5 秒内返回管线，实得 %s（旧写法只等信号量：作业排在占住的槽后面，永不返回）", atomic_load(&g_back) ? "返回了空" : "没返回");
    CHECK(g_pso_wait_inline == in0 + 1, "① 当场编计数期望 +1，实得 %llu → %llu", (unsigned long long)in0, (unsigned long long)g_pso_wait_inline);

    printf("· ② 放开槽：排着的后台块看到已认领、放手，不再编、不崩\n");
    nxgal_test_bg_hold(0); usleep(1000000);
    CHECK(g_pso_wait_inline == in0 + 1, "② 放开后当场编计数期望仍为 %llu，实得 %llu", (unsigned long long)(in0 + 1), (unsigned long long)g_pso_wait_inline);

    printf("· ③ 槽不占：另起一个作业，后台照常编完，当场编计数不变\n");
    gal_pso_job *j2 = gal_new_render_pso_async(desc(MTLPixelFormatBGRA8Unorm), &hit);
    int done = 0; id<MTLRenderPipelineState> p2 = nil;
    for (int i = 0; i < 1000 && j2 && !done; i++) { p2 = gal_pso_job_take(j2, &done); if (!done) usleep(10000); }
    CHECK(done && p2, "③ 期望后台 10 秒内编完取到管线，实得 编完 %d 管线 %p", done, (__bridge void *)p2);
    CHECK(g_pso_wait_inline == in0 + 1, "③ 当场编计数期望仍为 %llu，实得 %llu", (unsigned long long)(in0 + 1), (unsigned long long)g_pso_wait_inline);

    nxgal_shutdown();
    printf("%s：%d / %d 项通过\n", g_fail ? "失败" : "通过", g_checks - g_fail, g_checks);
    return g_fail ? 1 : 0;
}
GAL_MTL4_ZONE_END
