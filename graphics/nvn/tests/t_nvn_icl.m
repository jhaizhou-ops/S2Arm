// 间接绘制参数拷贝核 mdx_mask 的夹紧（#2320，graphics/nvn/gfx/nvn/nvn_mdx_msl.h）：在真 GPU 上跑这支核，逐字比输出。期望按核的规则手算，不跑宿主。
//   A Nintendo Switch Sports 现场的坏参数（索引数 22741334 × 实例数 22610265 > 2^28）→ 索引数夹成 0，计数 +1，记下任务号
//   B 索引数 1000、起始 100、索引缓冲只装得下 600 个 → 夹成 500
//   C 正常参数（612 × 1、缓冲装得下 1023 个）→ 原样，不计数
//   D 起始索引 700 已在缓冲外（装得下 600 个）→ 夹成 0
//   E 反证：同 A 但不夹（st 为空，DM_NVN_IND_CLAMP=0 的形态）→ 坏参数原样拷出（夹紧真的是这条规则做的，不是别处）
//   F 带计数的多重绘制、第 0 笔、计数 0 → 整条拷成 0（原 mdx_run 的掩码），不计数
//   G 不带索引（4 个字，3 × 1）→ 原样
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "../gfx/nvn/nvn_mdx_msl.h"

typedef struct { uint64_t rec, cnt, out, st; uint32_t i, words, id, pad; uint64_t lim; } mjob;   // as k_mdx_msl's mjob (nvn_mtl.m mdx_emit_q)
_Static_assert(sizeof(mjob) == 56, "mjob 与核里的 struct mjob 同布局");

static int bad;
#define CK(c, ...) do { if (c) printf("✓ " __VA_ARGS__); else { printf("✗ " __VA_ARGS__); bad++; } printf("\n"); } while (0)

int main(void) {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) { printf("没有 Metal 设备，跳过\n"); return 0; }
        NSError *e = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:@(k_mdx_msl) options:nil error:&e];
        id<MTLFunction> f = [lib newFunctionWithName:@"mdx_mask"];
        id<MTLComputePipelineState> ps = f ? [dev newComputePipelineStateWithFunction:f error:&e] : nil;
        if (!ps) { printf("✗ 编不过 mdx_mask：%s\n", e.localizedDescription.UTF8String); return 1; }
        enum { NJ = 7 };
        static const uint32_t rec[NJ][5] = {
            {22741334u, 22610265u, 22544732u, 22937947u, 22610265u},   // A
            {1000u, 1u, 100u, 0u, 0u},                                 // B
            {612u, 1u, 0u, 0u, 0u},                                    // C
            {10u, 1u, 700u, 0u, 0u},                                   // D
            {22741334u, 22610265u, 22544732u, 22937947u, 22610265u},   // E
            {9u, 1u, 0u, 0u, 0u},                                      // F
            {3u, 1u, 0u, 0u, 0u},                                      // G
        };
        id<MTLBuffer> rb = [dev newBufferWithBytes:rec length:sizeof rec options:MTLResourceStorageModeShared];
        id<MTLBuffer> ob = [dev newBufferWithLength:NJ * 32 options:MTLResourceStorageModeShared];
        id<MTLBuffer> sb = [dev newBufferWithLength:65 * 4 options:MTLResourceStorageModeShared];
        uint32_t zero = 0; id<MTLBuffer> cb = [dev newBufferWithBytes:&zero length:4 options:MTLResourceStorageModeShared];
        memset(ob.contents, 0xee, NJ * 32); memset(sb.contents, 0, 65 * 4);
        uint64_t r0 = rb.gpuAddress, o0 = ob.gpuAddress, s0 = sb.gpuAddress;
        mjob j[64] = {0};   // one threadgroup of 64, the rest padding (out 0)
        j[0] = (mjob){r0 + 0 * 20, 0, o0 + 0 * 32, s0, 0, 5, 7, 0, 0};
        j[1] = (mjob){r0 + 1 * 20, 0, o0 + 1 * 32, s0, 0, 5, 8, 0, 600};
        j[2] = (mjob){r0 + 2 * 20, 0, o0 + 2 * 32, s0, 0, 5, 9, 0, 1023};
        j[3] = (mjob){r0 + 3 * 20, 0, o0 + 3 * 32, s0, 0, 5, 10, 0, 600};
        j[4] = (mjob){r0 + 4 * 20, 0, o0 + 4 * 32, 0, 0, 5, 11, 0, 0};
        j[5] = (mjob){r0 + 5 * 20, cb.gpuAddress, o0 + 5 * 32, s0, 0, 5, 12, 0, 0};
        j[6] = (mjob){r0 + 6 * 20, 0, o0 + 6 * 32, s0, 0, 4, 13, 0, 0};
        id<MTLBuffer> jb = [dev newBufferWithBytes:j length:sizeof j options:MTLResourceStorageModeShared];
        id<MTLCommandQueue> q = [dev newCommandQueue]; id<MTLCommandBuffer> c = [q commandBuffer];
        id<MTLComputeCommandEncoder> ce = [c computeCommandEncoder];
        [ce setComputePipelineState:ps]; [ce setBuffer:jb offset:0 atIndex:0];
        [ce useResource:rb usage:MTLResourceUsageRead]; [ce useResource:cb usage:MTLResourceUsageRead];
        [ce useResource:ob usage:MTLResourceUsageWrite]; [ce useResource:sb usage:MTLResourceUsageRead | MTLResourceUsageWrite];
        [ce dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
        [ce endEncoding]; [c commit]; [c waitUntilCompleted];
        if (c.error) { printf("✗ 命令缓冲出错：%s\n", c.error.localizedDescription.UTF8String); return 1; }
        const uint32_t (*o)[8] = (const uint32_t (*)[8])ob.contents; const uint32_t *st = (const uint32_t *)sb.contents;
        CK(o[0][0] == 0 && o[0][1] == 22610265u && o[0][2] == 22544732u && o[0][3] == 22937947u && o[0][4] == 22610265u,
           "A 坏参数（2274 万 × 2261 万 > 2^28）：索引数夹成 0、其余照拷（实得 %u）", o[0][0]);
        CK(o[1][0] == 500 && o[1][2] == 100, "B 起始 100、缓冲装 600 个：索引数 1000 → 500（实得 %u）", o[1][0]);
        CK(!memcmp(o[2], rec[2], 20), "C 正常参数原样（实得 %u × %u）", o[2][0], o[2][1]);
        CK(o[3][0] == 0 && o[3][2] == 700, "D 起始 700 已在缓冲外：夹成 0（实得 %u）", o[3][0]);
        CK(o[4][0] == 22741334u && o[4][1] == 22610265u, "E 反证：不夹（st 空）时坏参数原样拷出（实得 %u × %u）", o[4][0], o[4][1]);
        CK(o[5][0] == 0 && o[5][1] == 0 && o[5][4] == 0, "F 计数 0 的多重绘制第 0 笔：整条拷成 0");
        CK(!memcmp(o[6], rec[6], 16) && o[6][4] == 0xeeeeeeeeu, "G 不带索引的 4 个字原样、第 5 个字不碰");
        uint32_t ids[3] = {st[1], st[2], st[3]}; int seen7 = 0, seen8 = 0, seen10 = 0;
        for (int k = 0; k < 3; k++) { seen7 |= ids[k] == 7; seen8 |= ids[k] == 8; seen10 |= ids[k] == 10; }
        CK(st[0] == 3 && seen7 && seen8 && seen10, "计数：夹了 A / B / D 三笔（实得 %u），记下的任务号 = {7, 8, 10}（实得 %u %u %u）；C / E / F / G 不计", st[0], ids[0], ids[1], ids[2]);
    }
    printf(bad ? "🔴 t_nvn_icl：%d 项不符\n" : "🟢 t_nvn_icl：全过\n", bad);
    return bad ? 1 : 0;
}
