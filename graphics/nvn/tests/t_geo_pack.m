// 几何着色器输出的有序压缩核（graphics/nvn/gfx/nvn/nvn_geometry.h k_nvn_geo_pack_msl）：手造每次调用的索引槽，期望手算，不跑被测实现。
//   11-02 Nintendo Switch Sports：原核一个线程逐个调用走完，每笔几何绘制约 3.9 ms，iOS 因此把 GPU 压到最低性能档（菜单 12 → 57 ms、广场 330 ms）；
//   改成一个线程组分块并行（计数 → 组内前缀和 → 各写各的），本测试守住「与逐个走完同顺序、同字、同截断」。
//   ① 三角带（topology 7），每调用 5 槽：g0 [10 11 12 13 −] → (10 11 12)(12 11 13)（第二个三角按带的奇偶换序）；g1 [20 21 − 22 23] 断开后都不满 3 个 → 无；
//      g2 [30 31 32 − −] → (30 31 32)。合 [10 11 12 12 11 13 30 31 32]，字数 9
//   ② 同输入、容量 7 字 → 只放得下 7 / 3 = 2 个整三角：[10 11 12 12 11 13]、字数 6，第 7 字不动
//   ③ 线带（topology 6），每调用 4 槽：g0 [1 2 3 −] → (1 2)(2 3)；g1 [− 4 5 −] → (4 5)。合 [1 2 2 3 4 5]，字数 6
//   ④ 点（topology 1），每调用 2 槽：g0 [7 −]、g1 [8 9] → [7 8 9]，字数 3
//   ⑤ 跨块：5000 次调用（大于一个线程组），三角带每调用 3 槽 [3g 3g+1 3g+2]，g mod 3 = 1 的整组是空槽 → 其余 3333 次各出 (3g 3g+1 3g+2)，按 g 递增；
//      字数 3333 × 3 = 9999。分别按 1024 线程（生产取法）与 32 线程（只有一个 SIMD 组）跑
#import <Metal/Metal.h>
#include <stdio.h>
#include <string.h>
#include "../gfx/nvn/nvn_geometry.h"
static int fail;
#define CHECK(c, ...) do { printf("%s ", (c) ? "✓" : "✗"); printf(__VA_ARGS__); putchar('\n'); if (!(c)) fail = 1; } while (0)
enum { X = 0xffffffffu, CAP = 16384 };
typedef struct { uint64_t src, dst, args; uint32_t groups, stride, topology, capacity; } pack_job;   // = struct geo_pack in the MSL (nvn_geometry.inc pj)
static id<MTLDevice> dev; static id<MTLComputePipelineState> ps; static id<MTLBuffer> src, dst, args, job;
// 跑一次：in 是 groups × stride 个槽；返回字数（args[0]），dst 里留结果（先填 0xeeeeeeee）
static uint32_t run(const uint32_t *in, uint32_t groups, uint32_t stride, uint32_t topology, uint32_t capacity, NSUInteger threads) {
    memcpy(src.contents, in, (size_t)groups * stride * 4); memset(dst.contents, 0xee, CAP * 4); memset(args.contents, 0xee, 32);
    pack_job j = {src.gpuAddress, dst.gpuAddress, args.gpuAddress, groups, stride, topology, capacity}; memcpy(job.contents, &j, sizeof j);
    id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer]; id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    [ce setComputePipelineState:ps]; [ce setBuffer:job offset:0 atIndex:0];
    for (id<MTLBuffer> u in @[src, dst, args]) [ce useResource:u usage:MTLResourceUsageRead | MTLResourceUsageWrite];
    [ce dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(threads, 1, 1)]; [ce endEncoding]; [cb commit]; [cb waitUntilCompleted];
    return ((uint32_t *)args.contents)[0];
}
int main(void) { @autoreleasepool {
    dev = MTLCreateSystemDefaultDevice(); if (!dev) { printf("✗ 没有 Metal 设备\n"); return 1; }
    NSError *e = nil; id<MTLLibrary> lib = [dev newLibraryWithSource:@(k_nvn_geo_pack_msl) options:nil error:&e];
    if (!lib) { printf("✗ 编不过：%s\n", e.localizedDescription.UTF8String); return 1; }
    ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"geo_pack_indices"] error:&e];
    if (!ps) { printf("✗ 管线建不出：%s\n", e.localizedDescription.UTF8String); return 1; }
    NSUInteger full = MIN(ps.maxTotalThreadsPerThreadgroup, 1024) / 32 * 32;   // 与 nvn_geometry.inc 派发同取法
    src = [dev newBufferWithLength:CAP * 4 options:0]; dst = [dev newBufferWithLength:CAP * 4 options:0]; args = [dev newBufferWithLength:32 options:0]; job = [dev newBufferWithLength:sizeof(pack_job) options:0];
    uint32_t *d = dst.contents, *a = args.contents;
    const uint32_t tri[15] = {10, 11, 12, 13, X, 20, 21, X, 22, 23, 30, 31, 32, X, X};
    uint32_t n = run(tri, 3, 5, 7, 30, full); const uint32_t w1[9] = {10, 11, 12, 12, 11, 13, 30, 31, 32};
    CHECK(n == 9 && !memcmp(d, w1, sizeof w1) && d[9] == 0xeeeeeeeeu && a[1] == 1 && !a[2] && !a[3] && !a[4],
          "① 三角带：[%u %u %u %u %u %u %u %u %u]、字数 %u（期望 [10 11 12 12 11 13 30 31 32]、9），间接参数其余 {1 0 0 0}", d[0], d[1], d[2], d[3], d[4], d[5], d[6], d[7], d[8], n);
    n = run(tri, 3, 5, 7, 7, full);
    CHECK(n == 6 && !memcmp(d, w1, 24) && d[6] == 0xeeeeeeeeu, "② 容量 7 字只放 2 个整三角：字数 %u（期望 6），第 7 字 %#x（期望不动 0xeeeeeeee）", n, d[6]);
    const uint32_t line[8] = {1, 2, 3, X, X, 4, 5, X};
    n = run(line, 2, 4, 6, 30, full); const uint32_t w3[6] = {1, 2, 2, 3, 4, 5};
    CHECK(n == 6 && !memcmp(d, w3, sizeof w3), "③ 线带：[%u %u %u %u %u %u]、字数 %u（期望 [1 2 2 3 4 5]、6）", d[0], d[1], d[2], d[3], d[4], d[5], n);
    const uint32_t pt[4] = {7, X, 8, 9};
    n = run(pt, 2, 2, 1, 30, full);
    CHECK(n == 3 && d[0] == 7 && d[1] == 8 && d[2] == 9 && d[3] == 0xeeeeeeeeu, "④ 点：[%u %u %u]、字数 %u（期望 [7 8 9]、3）", d[0], d[1], d[2], n);
    enum { G = 5000 }; static uint32_t big[G * 3], want[G * 3]; uint32_t nw = 0;
    for (uint32_t g = 0; g < G; g++) for (int i = 0; i < 3; i++) big[g * 3 + i] = g % 3 == 1 ? X : 3 * g + i;
    for (uint32_t g = 0; g < G; g++) if (g % 3 != 1) { want[nw++] = 3 * g; want[nw++] = 3 * g + 1; want[nw++] = 3 * g + 2; }
    NSUInteger tns[2] = {full, 32};
    for (int r = 0; r < 2; r++) {
        n = run(big, G, 3, 7, CAP, tns[r]); int bad = -1; for (uint32_t i = 0; i < 9999 && bad < 0; i++) if (d[i] != want[i]) bad = (int)i;
        CHECK(nw == 9999 && n == 9999 && bad < 0 && d[9999] == 0xeeeeeeeeu, "⑤ 跨块（%lu 线程）：字数 %u（期望 9999），首个不符位置 %d（期望 -1）", (unsigned long)tns[r], n, bad);
    }
    printf("%s t_geo_pack\n", fail ? "✗" : "✓"); return fail;
} }
