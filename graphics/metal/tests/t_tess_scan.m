// 单测 t_tess_scan：曲面细分前缀和（gal_tess.m s2a_tess_scan，审计 #854 F-tess-scan-u32）在 32 位折返处的容量检查。
// 造法（不经渲染器，老接口直接派发辅助库里的扫描核）：等值线点图元、因子 64 —— 每片 4160 点 / 4160 索引（gal_tess_d3d.h：65 点 × 64 条线，点输出索引数 = 点数），
//   片数 1100000（盖过 32 位折返的片号 1032444：1032444 × 4160 = 4294967040，再加 4160 按 uint32 折成 3904 ≤ 容量）。容量同宿主上限：点 2^20、索引 2^22。
// 期望（手算）：点先满。能放下的片数 = floor(2^20 / 4160) = 252（252 × 4160 = 1048320 ≤ 1048576，253 × 4160 = 1052480 超），
//   于是 cnt[0..251] 原样、cnt[252..] 全清零，绘制索引数 args[0] = 252 × 4160 = 1048320，丢弃数 stats[0] = 1100000 − 252，off[i] = i × 4160（i < 252）。
// 修前（uint32 前缀和）：折返后的片判成放得下，cnt 不清零、emit 照写 off ≈ 4294967040 —— 写出点 / 索引缓冲。
// 库走可执行文件旁 gal_helpers/m3/ 的 Metal 3 版（与运行时 Metal 4 版同一份 MSL，make 从当前源码导出）。
#include "../gal_abi.h"
#import <Metal/Metal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libgen.h>
#include <mach-o/dyld.h>

const char *nxgal_helper_src(int32_t k, const char **base);   // gal_core.m：第 k 个辅助库的源码 / 基名

static int g_fail, g_checks;
#define CHECK(cond, ...) do { g_checks++; if (!(cond)) { g_fail++; printf("  ✗ " __VA_ARGS__); printf("\n"); } } while (0)
enum { GH_TESS_K = 6, NP = 1100000, PER = 4160, PT_CAP = 1 << 20, IX_CAP = 1 << 22 };

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (!dev) { printf("没有 Metal 设备\n"); return 2; }
    char exe[4096]; uint32_t sz = sizeof exe;
    if (_NSGetExecutablePath(exe, &sz)) { printf("取本可执行文件路径失败\n"); return 2; }
    char dir[4096]; snprintf(dir, sizeof dir, "%s", dirname(exe));
    const char *base = NULL; nxgal_helper_src(GH_TESS_K, &base);
    char path[4600]; snprintf(path, sizeof path, "%s/gal_helpers/m3/%s.metallib", dir, base ? base : "?");
    NSError *e = nil;
    id<MTLLibrary> lib = [dev newLibraryWithURL:[NSURL fileURLWithPath:@(path)] error:&e];
    if (!lib) { printf("曲面辅助库载入失败：%s（%s）\n", path, e ? e.localizedDescription.UTF8String : "-"); return 2; }
    id<MTLFunction> fn = [lib newFunctionWithName:@"s2a_tess_scan"];
    id<MTLComputePipelineState> pso = fn ? [dev newComputePipelineStateWithFunction:fn error:&e] : nil;
    if (!pso) { printf("s2a_tess_scan 管线建不出：%s\n", e ? e.localizedDescription.UTF8String : "-"); return 2; }
    printf("· 曲面前缀和：%d 片 × %d 点 / 索引，容量 点 %d 索引 %d（片 1032444 处 32 位折返）\n", NP, PER, PT_CAP, IX_CAP);

    uint32_t prm[8] = {NP, 1, 1, 0, PT_CAP, IX_CAP, 12, 0};   // 等值线、整数分区、点图元
    id<MTLBuffer> bp = [dev newBufferWithBytes:prm length:sizeof prm options:MTLResourceStorageModeShared];
    id<MTLBuffer> bc = [dev newBufferWithLength:(NSUInteger)NP * 8 options:MTLResourceStorageModeShared];
    id<MTLBuffer> bo = [dev newBufferWithLength:(NSUInteger)NP * 8 options:MTLResourceStorageModeShared];
    id<MTLBuffer> ba = [dev newBufferWithLength:32 options:MTLResourceStorageModeShared];
    id<MTLBuffer> bs = [dev newBufferWithLength:64 options:MTLResourceStorageModeShared];
    if (!bp || !bc || !bo || !ba || !bs) { printf("建缓冲失败\n"); return 2; }
    uint32_t *cnt = bc.contents, *off = bo.contents, *args = ba.contents, *st = bs.contents;
    for (int i = 0; i < NP; i++) { cnt[2 * i] = PER; cnt[2 * i + 1] = PER; }
    memset(off, 0xEE, (size_t)NP * 8); memset(args, 0, 32); memset(st, 0, 64);

    id<MTLCommandQueue> q = [dev newCommandQueue];
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    [ce setComputePipelineState:pso];
    [ce setBuffer:bp offset:0 atIndex:0]; [ce setBuffer:bc offset:0 atIndex:2]; [ce setBuffer:bo offset:0 atIndex:3];
    [ce setBuffer:ba offset:0 atIndex:4]; [ce setBuffer:bs offset:0 atIndex:7];
    NSUInteger nt = pso.maxTotalThreadsPerThreadgroup < 1024 ? pso.maxTotalThreadsPerThreadgroup : 1024;   // 同 gal_tess_draw 的派发
    [ce dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(nt, 1, 1)];
    [ce endEncoding]; [cb commit]; [cb waitUntilCompleted];
    CHECK(cb.status == MTLCommandBufferStatusCompleted, "命令缓冲没完成：状态 %ld", (long)cb.status);

    enum { KEEP = PT_CAP / PER };   // 252
    int kept_bad = 0, off_bad = 0, live_after = 0, first_live = -1;
    for (int i = 0; i < KEEP; i++) { kept_bad += cnt[2 * i] != PER || cnt[2 * i + 1] != PER; off_bad += off[2 * i] != (uint32_t)i * PER || off[2 * i + 1] != (uint32_t)i * PER; }
    for (int i = KEEP; i < NP; i++) if (cnt[2 * i] || cnt[2 * i + 1]) { live_after++; if (first_live < 0) first_live = i; }
    printf("  · 放得下 %d 片；之后没清零的 %d 片（首个 %d，off = %u）；args[0] = %u；丢弃数 %u\n", KEEP, live_after, first_live,
           first_live >= 0 ? off[2 * first_live] : 0, args[0], st[0]);
    CHECK(kept_bad == 0 && off_bad == 0, "前 %d 片期望计数原样、off = i × %d，实得 计数错 %d 片 / off 错 %d 片", KEEP, PER, kept_bad, off_bad);
    CHECK(live_after == 0, "片 %d 起期望全部丢弃（计数清零），实得 %d 片没清零（首个片 %d：32 位前缀和折返后判成放得下，emit 会按越界 off 写）", KEEP, live_after, first_live);
    CHECK(cnt[2 * 1032444] == 0, "折返片 1032444 期望丢弃，实得计数 %u", cnt[2 * 1032444]);
    CHECK(args[0] == (uint32_t)KEEP * PER, "绘制索引数期望 %u（= %d × %d），实得 %u", (uint32_t)KEEP * PER, KEEP, PER, args[0]);
    CHECK(st[0] == (uint32_t)(NP - KEEP), "丢弃片数期望 %d，实得 %u", NP - KEEP, st[0]);
    printf("%s：%d / %d 项通过\n", g_fail ? "失败" : "通过", g_checks - g_fail, g_checks);
    return g_fail ? 1 : 0;
}
