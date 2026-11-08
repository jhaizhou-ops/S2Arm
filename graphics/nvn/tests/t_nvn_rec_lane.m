// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 录制分道（nvn_rec.h rec_lane / rec_lane_splice，几何绘制段 nvn_geometry.inc 用）：道 1 / 2 的记录先存着，拼接时接在主流后面，编码线程照「主流 → 道 1 → 道 2」执行。
// 期望按构造写死：每次派发一个线程，原子取号 i 后写 out[i] = 标签，所以 out 就是 GPU 上的执行顺序。三个计算编码器在提交线程上同时打开，录制顺序交错：
//   主 m1 → 道1 a1 → 道2 b1 → 主 m2 → 道1 a2 → 道2 b2，三个编码器各自收尾后拼接，拼接后主流再开一个编码器派发 m3。
//   ① 执行顺序 = [m1 m2 a1 a2 b1 b2 m3]（每次派发的标签缓冲地址在派发前写进参数表：各道的表写入跟着本道走，派发看到的是自己那一刻的表）
//   ② 编码线程上一次只开一个编码器：交错的编码器调用不串道（结果没有错标签、计数 7）
// 反证：rec_lane 改成空操作（不分道）→ 执行顺序 = 录制顺序 [m1 a1 b1 m2 a2 b2 m3]，① 红
#include "../gfx/nvn/nvn_mtl.m"

static unsigned checks, fails;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "SETUP FAIL %s:%d %s\n", __FILE__, __LINE__, #c); exit(2); } } while (0)
#define CHECK(c, ...) do { checks++; int ok_ = !!(c); fails += !ok_; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)

static id<MTLComputePipelineState> ps; static id<MTLBuffer> cnt, out, tags;
static void put(id ce, uint32_t tag) {   // 一次派发：槽 0 计数、槽 1 输出、槽 2 标签（tags 里第 tag 个字 = tag）
    enc_c_pso(ce, ps); enc_c_args(ce, cnt.gpuAddress, 0); enc_c_args(ce, out.gpuAddress, 1); enc_c_args(ce, tags.gpuAddress + tag * 4, 2);
    enc_c_dispatch(ce, MTLSizeMake(1, 1, 1), MTLSizeMake(1, 1, 1));
    enc_c_inner_barrier(ce);   // 同一编码器里两次派发不加屏障时 Metal 4 可以并发、先后不定（几何绘制段每次派发后也有这一道）
}
static id lane_ce(int k) { rec_lane(k); id e = [(id<MTL4CommandBuffer>)g_cb computeCommandEncoder]; enc_full_barrier_begin(e); enc_c_table(e, g_ct); rec_lane(0); return e; }
static void lane_end(int k, id e) { rec_lane(k); enc_full_barrier_end(e); [(id<MTL4CommandEncoder>)e endEncoding]; rec_lane(0); }

int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IOLBF, 0);
    setenv("DM_NVN_ENC_THREAD", "1", 1);   // Mac 缺省不开录制线程；分道只在录制流里存在
    mtl_init(); REQUIRE(!g_m3); REQUIRE(rec_on());
    NSError *e = nil;
    id<MTLLibrary> lib = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "kernel void k(device atomic_uint *c [[buffer(0)]], device uint *o [[buffer(1)]], device const uint *t [[buffer(2)]]) {"
        " uint i = atomic_fetch_add_explicit(c, 1u, memory_order_relaxed); o[i] = t[0]; }" options:nil error:&e];
    if (!lib) fprintf(stderr, "MSL: %s\n", e.localizedDescription.UTF8String); REQUIRE(lib);
    ps = [g_dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&e]; REQUIRE(ps);
    cnt = [g_dev newBufferWithLength:16 options:MTLResourceStorageModeShared]; out = [g_dev newBufferWithLength:64 options:MTLResourceStorageModeShared];
    tags = [g_dev newBufferWithLength:64 options:MTLResourceStorageModeShared]; REQUIRE(cnt && out && tags);
    res_add(cnt); res_add(out); res_add(tags);
    uint32_t *tg = tags.contents; for (uint32_t i = 0; i < 16; i++) tg[i] = i;   // 标签 = 字号
    enum { M1 = 1, M2 = 2, M3 = 3, A1 = 4, A2 = 5, B1 = 6, B2 = 7 };
    memset(cnt.contents, 0, 16); memset(out.contents, 0xff, 64);
    nvn_be_sub_begin();
    id m = [(id<MTL4CommandBuffer>)g_cb computeCommandEncoder]; enc_full_barrier_begin(m); enc_c_table(m, g_ct);
    id a = lane_ce(1), b = lane_ce(2);
    put(m, M1); rec_lane(1); put(a, A1); rec_lane(2); put(b, B1); rec_lane(0);
    put(m, M2); rec_lane(1); put(a, A2); rec_lane(2); put(b, B2); rec_lane(0);
    enc_full_barrier_end(m); [(id<MTL4CommandEncoder>)m endEncoding];
    lane_end(1, a); lane_end(2, b);
    rec_lane_splice();
    id m3 = [(id<MTL4CommandBuffer>)g_cb computeCommandEncoder]; enc_full_barrier_begin(m3); enc_c_table(m3, g_ct); put(m3, M3); enc_full_barrier_end(m3); [(id<MTL4CommandEncoder>)m3 endEncoding];
    uint64_t fe = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(fe, 10000000000ull)); REQUIRE(!mtl_last_commit_error());
    const uint32_t *o = out.contents; uint32_t n = ((const uint32_t *)cnt.contents)[0];
    const uint32_t want[7] = {M1, M2, A1, A2, B1, B2, M3};
    CHECK(n == 7 && !memcmp(o, want, sizeof want), "① 执行顺序 [%u %u %u %u %u %u %u]（期望 [1 2 4 5 6 7 3] = m1 m2 a1 a2 b1 b2 m3），派发 %u 次（期望 7）", o[0], o[1], o[2], o[3], o[4], o[5], o[6], n);
    int bad = 0; for (uint32_t i = 0; i < n && i < 16; i++) if (o[i] < 1 || o[i] > 7) bad++;
    CHECK(n == 7 && !bad, "② 没有串道的标签（错标签 %d 个，期望 0）", bad);
} printf("%s t_nvn_rec_lane：%u 项，失败 %u\n", fails ? "✗" : "✓", checks, fails); return fails ? 1 : 0; }
