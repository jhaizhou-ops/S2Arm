// 无 BC 显卡上 BC1–5 的 GPU 解压核 bcd（graphics/nvn/gfx/tex/nvn_bcd_msl.h）单测：真值 = CPU 端 bcdec（nvn_bcdec.c，独立实现、无 BC 显卡的 CPU 路径就用它）。
// 每种格式（BC1 / BC2 / BC3 / BC4 / BC4 有符号 / BC5 / BC5 有符号）一张 13×10 贴图（右、下边是不满 4×4 的块），块内容 = 固定种子随机 + 几个特殊块
// （BC1 三色带透明模式 c0 ≤ c1、BC4 六值模式 a0 ≤ a1、有符号端点 -128），GPU 解进解压格式贴图读回，逐纹素逐通道比：
// 期望每通道差 ≤ 1 级（核按浮点插值、写贴图时舍入，bcdec 按整数近似；差 1 级是两种舍入的固有差，差 2 级以上就是解错了），且解出的纹素数 = 13 × 10。
#import <Metal/Metal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../gfx/tex/nvn_bcd_msl.h"
#include "../gfx/tex/nvn_bcdec.h"

int main(void) {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) { printf("t_bcd_gpu: 没有 Metal 设备\n"); return 1; }
        NSError *e = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:@(k_bcd_msl) options:nil error:&e];
        id<MTLComputePipelineState> ps = lib ? [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"bcd"] error:&e] : nil;
        if (!ps) { printf("t_bcd_gpu: 解压核建不出：%s\n", e.localizedDescription.UTF8String); return 1; }
        id<MTLCommandQueue> q = [dev newCommandQueue];
        static const struct { uint32_t nvn, kf, bb, ch; int sn; MTLPixelFormat pf; const char *name; } F[] = {
            {0x42, 1, 8, 4, 0, MTLPixelFormatRGBA8Unorm, "BC1"}, {0x43, 2, 16, 4, 0, MTLPixelFormatRGBA8Unorm, "BC2"}, {0x44, 3, 16, 4, 0, MTLPixelFormatRGBA8Unorm, "BC3"},
            {0x49, 4, 8, 1, 0, MTLPixelFormatR8Unorm, "BC4"}, {0x4a, 5, 8, 1, 1, MTLPixelFormatR8Snorm, "BC4 有符号"},
            {0x4b, 6, 16, 2, 0, MTLPixelFormatRG8Unorm, "BC5"}, {0x4c, 7, 16, 2, 1, MTLPixelFormatRG8Snorm, "BC5 有符号"},
        };
        const uint32_t W = 13, H = 10, BX = (W + 3) / 4, BY = (H + 3) / 4;
        int bad = 0;
        for (size_t k = 0; k < sizeof F / sizeof F[0]; k++) {
            uint32_t pitch = BX * F[k].bb; size_t n = (size_t)pitch * BY; uint8_t *blk = malloc(n);
            srand(1026 + (unsigned)k); for (size_t i = 0; i < n; i++) blk[i] = (uint8_t)(rand() >> 7);
            // 特殊块：第 0 块走少见分支（BC1 c0 ≤ c1 的三色 + 透明；单通道 a0 ≤ a1 的六值 + 0 / 1；有符号端点 -128 夹到 -127）
            if (F[k].kf == 1) { blk[0] = 0x10; blk[1] = 0x20; blk[2] = 0x30; blk[3] = 0x40; }
            if (F[k].kf >= 4) { blk[0] = F[k].sn ? 0x80 : 0x20; blk[1] = 0x70; }
            if (F[k].kf == 3) { blk[0] = 0x20; blk[1] = 0x90; }
            id<MTLBuffer> src = [dev newBufferWithBytes:blk length:n options:MTLResourceStorageModeShared];
            struct { uint32_t off, pitch, w, h, fmt, z; } p = {0, pitch, W, H, F[k].kf, 0};
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:F[k].pf width:W height:H mipmapped:NO];
            td.storageMode = MTLStorageModeShared; td.usage = MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead;
            id<MTLTexture> tex = [dev newTextureWithDescriptor:td];
            id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
            [ce setComputePipelineState:ps]; [ce setBuffer:src offset:0 atIndex:0]; [ce setBytes:&p length:sizeof p atIndex:1]; [ce setTexture:tex atIndex:0];
            [ce dispatchThreadgroups:MTLSizeMake((BX + 7) / 8, (BY + 7) / 8, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
            [ce endEncoding]; [cb commit]; [cb waitUntilCompleted];
            size_t dp = (size_t)W * F[k].ch; uint8_t *gpu = calloc(dp * H, 1), *cpu = calloc(dp * H, 1);
            [tex getBytes:gpu bytesPerRow:dp fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];
            if (nvn_bc_decode(F[k].nvn, blk, pitch, W, H, cpu, dp)) { printf("✗ %s：bcdec 不认这个格式\n", F[k].name); bad = 1; continue; }
            int mx = 0, nd = 0;
            for (size_t i = 0; i < dp * H; i++) { int a = F[k].sn ? (int8_t)gpu[i] : gpu[i], b = F[k].sn ? (int8_t)cpu[i] : cpu[i], d = abs(a - b); if (d > mx) mx = d; nd += d != 0; }
            int ok = mx <= 1;
            printf("%s %s：%u×%u 共 %u 个纹素 × %u 通道，与 bcdec 最大差 %d 级（有差的 %d 个）\n", ok ? "✓" : "✗", F[k].name, W, H, W * H, F[k].ch, mx, nd);
            bad |= !ok; free(blk); free(gpu); free(cpu);
        }
        if (bad) printf("✗ t_bcd_gpu：有格式与 bcdec 差 2 级以上\n"); else printf("✓ t_bcd_gpu：7 种格式与 bcdec 逐纹素比全过\n");
        return bad;
    }
}
