// 单测 t_nvn_tess_bounds：直连曲面细分的两处越界（审计 1101 P0-5 / P0-6），用生产同一份核源码（nvn_tess_msl）与同一份派发规划（nvn_tess_tcs_grid）。
// ① 前缀和折返（P0-6，同 graphics/metal/tests/t_tess_scan.m 的通用层用例）：等值线点图元因子 64 每片 4160 点 / 4160 索引，1100000 片（盖过 32 位折返的片号 1032444：
//   1032444 × 4160 = 4294967040，再加 4160 按 uint32 折成 3904 ≤ 容量），容量 点 2^20、索引 2^22（同宿主 TESS_PT_CAP / TESS_IX_CAP）。
//   期望（手算）：点先满，放得下 floor(2^20 / 4160) = 252 片；cnt[0..251] 原样、off[i] = i × 4160，cnt[252..] 全清零，绘制索引数 args[0] = 252 × 4160 = 1048320。
//   修前（uint2 前缀和）：折返后的片判成放得下、cnt 不清零，emit 按 off ≈ 4294967040 写出点 / 索引缓冲。
// ② TCS 派发不补满（P0-5）：多片工作组的核（SPIRV-Cross MSL_MULTI_PATCH_WORKGROUP）只把输入与 gl_PrimitiveID 夹到最后一片，控制点输出按全局线程号写、不夹。
//   这里用一个同样「按全局线程号写、不夹」的核按 nvn_tess_tcs_grid 派发，输出缓冲 Pt × N 格后放哨兵。
//   期望（手算）：N = 3、Pt = 1 → 每组 per = 10 片、30 线程，总线程 3：写 3 格、哨兵不动；N = 3、Pt = 7 → 写 21 格；N = 32、Pt = 2 → 写 64 格；N = 5、Pt = 13 → 写 65 格。
//   修前（按组派发、最后一组补满到 per × N）：N = 3、Pt = 1 写 30 格，哨兵被改（生产里紧跟着的是因子缓冲）。
// ③ 计数 / 写出按片数派发（审计 1101 18:00 P1-42，nvn_tess_patch_grid）：每个起来的线程原子加 1 的核按规划派发，Pt = 1 / 63 / 64 / 65 / 100000，
//   期望（手算）起来的线程数 = Pt；反证：旧派发（组数 = Pt、每组 64）起来 64 × Pt 个。生产 nvn_tess_count 按同一规划跑 65 片（等值线、因子全 1）：
//   cnt[0..64] 都写了（每片恰算一次，结果同旧派发），cnt[65..] 哨兵不动
#import <Metal/Metal.h>
#include <stdio.h>
#include <string.h>
#include "../gfx/nvn/nvn_builtin.h"
static int g_fail, g_checks;
#define CHECK(c, ...) do { g_checks++; printf("%s ", (c) ? "✓" : "✗"); printf(__VA_ARGS__); putchar('\n'); if (!(c)) g_fail++; } while (0)
enum { NP = 1100000, PER = 4160, PT_CAP = 1 << 20, IX_CAP = 1 << 22, KEEP = PT_CAP / PER, SENT = 64 };

static const char k_tcs_like[] =
    "#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void tcs_like(device uint* out [[buffer(0)]], uint gid [[thread_position_in_grid]]) { out[gid] = 1u; }\n";

int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IONBF, 0);
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (!dev) { printf("✗ 没有 Metal 设备\n"); return 2; }
    NSError *e = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:nvn_tess_msl() options:nil error:&e];   // 与生产 tess_init 同一份拼法
    if (!lib) { printf("✗ 细分核编不过：%s\n", e.localizedDescription.UTF8String); return 2; }
    id<MTLComputePipelineState> scan = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"nvn_tess_scan"] error:&e];
    id<MTLLibrary> lib2 = [dev newLibraryWithSource:@(k_tcs_like) options:nil error:&e];
    id<MTLComputePipelineState> tcs = lib2 ? [dev newComputePipelineStateWithFunction:[lib2 newFunctionWithName:@"tcs_like"] error:&e] : nil;
    if (!scan || !tcs) { printf("✗ 管线建不出：%s\n", e ? e.localizedDescription.UTF8String : "-"); return 2; }
    id<MTLCommandQueue> q = [dev newCommandQueue];

    // ① 前缀和折返
    uint32_t prm[8] = {NP, 1, 1, 0, PT_CAP, IX_CAP, nvn_tess_fstride(0), 0};   // 等值线、整数分区、点图元
    id<MTLBuffer> bp = [dev newBufferWithBytes:prm length:sizeof prm options:MTLResourceStorageModeShared];
    id<MTLBuffer> bc = [dev newBufferWithLength:(NSUInteger)NP * 8 options:MTLResourceStorageModeShared];
    id<MTLBuffer> bo = [dev newBufferWithLength:(NSUInteger)NP * 8 options:MTLResourceStorageModeShared];
    id<MTLBuffer> ba = [dev newBufferWithLength:32 options:MTLResourceStorageModeShared];
    uint32_t *cnt = bc.contents, *off = bo.contents, *args = ba.contents;
    for (int i = 0; i < NP; i++) { cnt[2 * i] = PER; cnt[2 * i + 1] = PER; }
    memset(off, 0xEE, (size_t)NP * 8); memset(args, 0, 32);
    id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    [ce setComputePipelineState:scan];
    [ce setBuffer:bp offset:0 atIndex:0]; [ce setBuffer:bc offset:0 atIndex:2]; [ce setBuffer:bo offset:0 atIndex:3]; [ce setBuffer:ba offset:0 atIndex:4];
    NSUInteger nt = scan.maxTotalThreadsPerThreadgroup < 1024 ? scan.maxTotalThreadsPerThreadgroup : 1024;   // 同 nvn_mtl.m tess_draw 的派发
    [ce dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(nt, 1, 1)];
    [ce endEncoding]; [cb commit]; [cb waitUntilCompleted];
    CHECK(cb.status == MTLCommandBufferStatusCompleted, "扫描命令缓冲完成（状态 %ld）", (long)cb.status);
    int kept_bad = 0, off_bad = 0, live_after = 0, first_live = -1;
    for (int i = 0; i < KEEP; i++) { kept_bad += cnt[2 * i] != PER || cnt[2 * i + 1] != PER; off_bad += off[2 * i] != (uint32_t)i * PER || off[2 * i + 1] != (uint32_t)i * PER; }
    for (int i = KEEP; i < NP; i++) if (cnt[2 * i] || cnt[2 * i + 1]) { live_after++; if (first_live < 0) first_live = i; }
    CHECK(kept_bad == 0 && off_bad == 0, "前 %d 片计数原样、off = i × %d（计数错 %d 片、off 错 %d 片）", KEEP, PER, kept_bad, off_bad);
    CHECK(live_after == 0, "片 %d 起全部丢弃（没清零 %d 片，首个 %d：32 位前缀和折返后判成放得下）", KEEP, live_after, first_live);
    CHECK(cnt[2 * 1032444] == 0, "折返片 1032444 丢弃（计数 %u）", cnt[2 * 1032444]);
    CHECK(args[0] == (uint32_t)KEEP * PER, "绘制索引数 %u（期望 %u = %d × %d）", args[0], (uint32_t)KEEP * PER, KEEP, PER);

    // ② TCS 派发不补满
    static const struct { uint32_t n; uint64_t pt; } tc[] = {{3, 1}, {3, 7}, {32, 2}, {5, 13}};
    for (unsigned k = 0; k < sizeof tc / sizeof tc[0]; k++) {
        uint64_t threads; uint32_t group; nvn_tess_tcs_grid(tc[k].n, tc[k].pt, &threads, &group);
        uint64_t want = tc[k].pt * tc[k].n;
        id<MTLBuffer> bt = [dev newBufferWithLength:(NSUInteger)(want + SENT) * 4 options:MTLResourceStorageModeShared];
        uint32_t *o = bt.contents; memset(o, 0, (size_t)(want + SENT) * 4);
        cb = [q commandBuffer]; ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:tcs]; [ce setBuffer:bt offset:0 atIndex:0];
        [ce dispatchThreads:MTLSizeMake(threads, 1, 1) threadsPerThreadgroup:MTLSizeMake(group, 1, 1)];   // 同 nvn_mtl.m enc_c_dispatch_threads
        [ce endEncoding]; [cb commit]; [cb waitUntilCompleted];
        uint64_t written = 0, over = 0; for (uint64_t i = 0; i < want; i++) written += o[i] == 1; for (uint64_t i = want; i < want + SENT; i++) over += o[i] != 0;
        CHECK(group % tc[k].n == 0 && written == want && over == 0, "N %u、Pt %llu：每组 %u 线程，写满 %llu / %llu 格，越过 Pt × N 写了 %llu 格（期望 0）",
              tc[k].n, (unsigned long long)tc[k].pt, group, (unsigned long long)written, (unsigned long long)want, (unsigned long long)over);
    }
    // ③ 计数 / 写出按片数派发
    {
        id<MTLLibrary> lib3 = [dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\nkernel void grid_count(device atomic_uint* c [[buffer(0)]], uint pid [[thread_position_in_grid]]) { atomic_fetch_add_explicit(c, 1u, memory_order_relaxed); }\n" options:nil error:&e];
        id<MTLComputePipelineState> gc = lib3 ? [dev newComputePipelineStateWithFunction:[lib3 newFunctionWithName:@"grid_count"] error:&e] : nil;
        id<MTLComputePipelineState> pc = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"nvn_tess_count"] error:&e];
        CHECK(gc && pc, "③ 管线建得出");
        id<MTLBuffer> bn = [dev newBufferWithLength:4 options:MTLResourceStorageModeShared];
        static const uint64_t pts[] = {1, 63, 64, 65, 100000};
        for (unsigned k = 0; gc && k < sizeof pts / sizeof pts[0]; k++) for (int old = 0; old < 2; old++) {
            *(uint32_t *)bn.contents = 0; uint64_t th; uint32_t gr; nvn_tess_patch_grid(pts[k], &th, &gr);
            cb = [q commandBuffer]; ce = [cb computeCommandEncoder]; [ce setComputePipelineState:gc]; [ce setBuffer:bn offset:0 atIndex:0];
            if (old) [ce dispatchThreadgroups:MTLSizeMake(pts[k], 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];   // 改前的派发
            else [ce dispatchThreads:MTLSizeMake(th, 1, 1) threadsPerThreadgroup:MTLSizeMake(gr, 1, 1)];   // 同 nvn_mtl.m enc_c_dispatch_threads
            [ce endEncoding]; [cb commit]; [cb waitUntilCompleted];
            uint64_t got = *(uint32_t *)bn.contents, want = old ? pts[k] * 64 : pts[k];
            CHECK(got == want, "Pt %llu %s：起来 %llu 个线程（期望 %llu）", (unsigned long long)pts[k], old ? "旧派发（反证）" : "按片数", (unsigned long long)got, (unsigned long long)want);
        }
        enum { NPC = 65, SEN = 64 };
        uint32_t fs = nvn_tess_fstride(0); id<MTLBuffer> bf = [dev newBufferWithLength:(NSUInteger)fs * NPC options:MTLResourceStorageModeShared];
        for (unsigned i = 0; i < fs * NPC / 2; i++) ((uint16_t *)bf.contents)[i] = 0x3C00;   // half 1.0
        uint32_t pr[8] = {NPC, 1, 1, 0, PT_CAP, IX_CAP, fs, 0};
        id<MTLBuffer> bpr = [dev newBufferWithBytes:pr length:sizeof pr options:MTLResourceStorageModeShared], bcn = [dev newBufferWithLength:(NPC + SEN) * 8 options:MTLResourceStorageModeShared];
        memset(bcn.contents, 0xAB, (NPC + SEN) * 8);
        uint64_t th; uint32_t gr; nvn_tess_patch_grid(NPC, &th, &gr);
        cb = [q commandBuffer]; ce = [cb computeCommandEncoder]; [ce setComputePipelineState:pc];
        [ce setBuffer:bpr offset:0 atIndex:0]; [ce setBuffer:bf offset:0 atIndex:1]; [ce setBuffer:bcn offset:0 atIndex:2];
        [ce dispatchThreads:MTLSizeMake(th, 1, 1) threadsPerThreadgroup:MTLSizeMake(gr, 1, 1)]; [ce endEncoding]; [cb commit]; [cb waitUntilCompleted];
        const uint32_t *cc = bcn.contents; int done = 0, over = 0;
        for (int i = 0; i < NPC; i++) done += cc[2 * i] != 0xABABABABu && cc[2 * i] > 0;
        for (int i = NPC; i < NPC + SEN; i++) over += cc[2 * i] != 0xABABABABu || cc[2 * i + 1] != 0xABABABABu;
        CHECK(done == NPC && over == 0, "生产 nvn_tess_count 按片数派发 %d 片：算到 %d 片（每片点数 %u），越过片数写了 %d 格（期望 0）", NPC, done, cc[0], over);
    }
    printf("%s：%d / %d 项通过\n", g_fail ? "失败" : "通过", g_checks - g_fail, g_checks);
    return g_fail ? 1 : 0;
} }
