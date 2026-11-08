// t_fold.py 的 GPU 执行器：折行贴图对拍（nvn_red.h nvn_se_fold + S2A.Dsh RedHelp s2a_fx / s2a_ff）。
//   用法：t_fold_run <名> <原样 main0 的 MSL> <fs_rd 变体 MSL> [<名> <MSL> <MSL> …]；每个（核 × k × 过滤 × 寻址）一行 ✓ / ✗，退出 0 = 全过、1 = 有不过
//   期望 = 原样 main0 + Metal 硬件采样逻辑贴图（W×H R32Float，2D 数组的是 1 层）；真结果 = 变体 + 折行贴图（同一份数据按 k 行一行、行距补齐到 P 纹素放进共享缓冲建的线性贴图）
//   + 表项 nvn_se_fold（放在采样器成员 id 1 处）。逐点差 ≤ 1/256 + 1e-6（硬件双线性权重 8 位定点）。反证：同一变体换零表项（不当折行读）必须有对不上的
#import <Metal/Metal.h>
#include <stdio.h>
#include <string.h>
#include "nvn_red.h"

enum { W = 12, H = 40, P = 16, NPT = 64 };
static int fails;
static float val(int x, int y) { uint32_t h = (uint32_t)x * 73856093u ^ (uint32_t)y * 19349663u; h ^= h >> 13; h *= 0x5bd1e995u; h ^= h >> 15; return (float)(h & 1023u) / 1023.0f; }
static id<MTLLibrary> lib(id<MTLDevice> d, const char *p) {
    NSError *e = nil; NSString *s = [NSString stringWithContentsOfFile:@(p) encoding:NSUTF8StringEncoding error:&e];
    id<MTLLibrary> l = s ? [d newLibraryWithSource:s options:nil error:&e] : nil;
    if (!l) { printf("✗ %s 编不过：%s\n", p, e.localizedDescription.UTF8String); exit(1); }
    return l;
}
static id<MTLComputePipelineState> pipe_(id<MTLDevice> d, id<MTLLibrary> l) {
    NSError *e = nil; id<MTLComputePipelineState> p = [d newComputePipelineStateWithFunction:[l newFunctionWithName:@"main0"] error:&e];
    if (!p) { printf("✗ 管线建不出：%s\n", e.localizedDescription.UTF8String); exit(1); }
    return p;
}
// 跑一支核：参数块（id 0 贴图、1 采样器、2 输出、3 位置），可选模拟表（缓冲 26）
static void run(id<MTLDevice> d, id<MTLCommandQueue> q, id<MTLComputePipelineState> ps, id<MTLFunction> fn, id<MTLTexture> t, id<MTLSamplerState> s, id<MTLBuffer> pos, id<MTLBuffer> out, id<MTLBuffer> tab) {
    id<MTLArgumentEncoder> ae = [fn newArgumentEncoderWithBufferIndex:0];
    id<MTLBuffer> ab = [d newBufferWithLength:ae.encodedLength options:MTLResourceStorageModeShared];
    [ae setArgumentBuffer:ab offset:0]; [ae setTexture:t atIndex:0]; [ae setSamplerState:s atIndex:1]; [ae setBuffer:out offset:0 atIndex:2]; [ae setBuffer:pos offset:0 atIndex:3];
    id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> en = [cb computeCommandEncoder];
    [en setComputePipelineState:ps]; [en setBuffer:ab offset:0 atIndex:0]; if (tab) [en setBuffer:tab offset:0 atIndex:26];
    [en useResource:t usage:MTLResourceUsageRead]; [en useResource:out usage:MTLResourceUsageWrite]; [en useResource:pos usage:MTLResourceUsageRead];
    [en dispatchThreads:MTLSizeMake(NPT, 1, 1) threadsPerThreadgroup:MTLSizeMake(NPT, 1, 1)]; [en endEncoding]; [cb commit]; [cb waitUntilCompleted];
}
int main(int argc, char **argv) { @autoreleasepool {
    id<MTLDevice> d = MTLCreateSystemDefaultDevice(); id<MTLCommandQueue> q = [d newCommandQueue];
    float data[H][W]; for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) data[y][x] = val(x, y);
    // NVN 寻址 → Metal 寻址：0 夹边、1 重复、6 镜像重复、2 镜像夹边、5 夹边框（nvn_red.h nvn_samp_wrap 的对照）
    const struct { int nvn; MTLSamplerAddressMode m; const char *n; } WR[] = {{0, MTLSamplerAddressModeClampToEdge, "夹边"}, {1, MTLSamplerAddressModeRepeat, "重复"},
        {6, MTLSamplerAddressModeMirrorRepeat, "镜像重复"}, {2, MTLSamplerAddressModeMirrorClampToEdge, "镜像夹边"}, {5, MTLSamplerAddressModeClampToBorderColor, "夹边框"}};
    for (int a = 1; a + 2 < argc; a += 3) {
        const char *nm = argv[a]; int arr = strstr(nm, "arr") != NULL, grad = strstr(nm, "gr") != NULL;
        id<MTLLibrary> lm = lib(d, argv[a + 1]), lv = lib(d, argv[a + 2]);
        id<MTLComputePipelineState> pm = pipe_(d, lm), pv = pipe_(d, lv); id<MTLFunction> fm = [lm newFunctionWithName:@"main0"], fv = [lv newFunctionWithName:@"main0"];
        // 逻辑贴图（期望那一路）
        MTLTextureDescriptor *td = [MTLTextureDescriptor new]; td.textureType = arr ? MTLTextureType2DArray : MTLTextureType2D; td.pixelFormat = MTLPixelFormatR32Float;
        td.width = W; td.height = H; td.arrayLength = 1; td.storageMode = MTLStorageModeShared; td.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> lt = [d newTextureWithDescriptor:td]; [lt replaceRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0 slice:0 withBytes:data bytesPerRow:W * 4 bytesPerImage:W * H * 4];
        // 位置：u、v 跨出 [0, 1]（寻址），LOD 两档（放大 / 缩小），2D 数组层号 0
        id<MTLBuffer> pos = [d newBufferWithLength:NPT * 16 options:MTLResourceStorageModeShared]; float *pp = pos.contents;
        for (int i = 0; i < NPT; i++) { pp[4 * i] = -0.37f + 1.73f * (float)(i % 8) / 7.0f + 0.013f * (float)i; pp[4 * i + 1] = -0.29f + 1.61f * (float)(i / 8) / 7.0f;
            pp[4 * i + 2] = grad ? (i & 1 ? 12.0f : -3.0f) : (i & 1 ? 1.5f : -1.0f); pp[4 * i + 3] = 0.0f; }
        for (int k = 2; k <= 3; k++) {
            // 折行贴图：逻辑行 y 放在 y × P 纹素处（行距补齐到 P），按 k 行一行建线性贴图（宽 (k − 1)·P + W，高 ⌈H/k⌉，行距 k·P·4 字节）
            int fh = (H + k - 1) / k; id<MTLBuffer> fb = [d newBufferWithLength:(size_t)fh * k * P * 4 options:MTLResourceStorageModeShared]; memset(fb.contents, 0, fb.length);
            for (int y = 0; y < H; y++) memcpy((float *)fb.contents + (size_t)y * P, data[y], W * 4);
            MTLTextureDescriptor *fd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float width:(NSUInteger)(k - 1) * P + W height:fh mipmapped:NO];
            fd.storageMode = MTLStorageModeShared; fd.usage = MTLTextureUsageShaderRead;
            id<MTLTexture> ft = [fb newTextureWithDescriptor:fd offset:0 bytesPerRow:(NSUInteger)k * P * 4];
            if (arr) ft = [ft newTextureViewWithPixelFormat:MTLPixelFormatR32Float textureType:MTLTextureType2DArray levels:NSMakeRange(0, 1) slices:NSMakeRange(0, 1)];
            if (!ft) { printf("✗ %s k=%d：折行贴图建不出\n", nm, k); fails++; continue; }
            for (int minf = 0; minf < 2; minf++) for (int magf = 0; magf < 2; magf++) for (int w = 0; w < 5; w++) for (int bc = 0; bc < (WR[w].nvn == 5 ? 2 : 1); bc++) {
                MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new]; sd.minFilter = minf ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
                sd.magFilter = magf ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest; sd.mipFilter = MTLSamplerMipFilterNotMipmapped;
                sd.sAddressMode = sd.tAddressMode = WR[w].m; sd.borderColor = bc ? MTLSamplerBorderColorOpaqueWhite : MTLSamplerBorderColorTransparentBlack; sd.supportArgumentBuffers = YES;
                id<MTLSamplerState> ss = [d newSamplerStateWithDescriptor:sd];
                float border[4] = {bc, bc, bc, bc};
                nvn_se_ent tab[4]; memset(tab, 0, sizeof tab);
                nvn_se_fold(minf, magf, WR[w].nvn, WR[w].nvn, -1000.0f, 1000.0f, 0.0f, 1, border, W, H, P, k, &tab[1]);
                id<MTLBuffer> tb = [d newBufferWithBytes:tab length:sizeof tab options:MTLResourceStorageModeShared], z = [d newBufferWithLength:sizeof tab options:MTLResourceStorageModeShared];
                id<MTLBuffer> oe = [d newBufferWithLength:NPT * 4 options:MTLResourceStorageModeShared], og = [d newBufferWithLength:NPT * 4 options:MTLResourceStorageModeShared],
                              on = [d newBufferWithLength:NPT * 4 options:MTLResourceStorageModeShared];
                run(d, q, pm, fm, lt, ss, pos, oe, nil); run(d, q, pv, fv, ft, ss, pos, og, tb); run(d, q, pv, fv, ft, ss, pos, on, z);
                const float *e = oe.contents, *g = og.contents, *nf = on.contents; int bad = -1, diff_neg = 0;
                for (int i = 0; i < NPT; i++) { if (bad < 0 && fabsf(e[i] - g[i]) > 1.0f / 256 + 1e-6f) bad = i; if (fabsf(e[i] - nf[i]) > 1.0f / 256 + 1e-6f) diff_neg = 1; }
                char lab[160]; snprintf(lab, sizeof lab, "%s k=%d 缩小%s 放大%s %s%s", nm, k, minf ? "线性" : "最近", magf ? "线性" : "最近", WR[w].n, WR[w].nvn == 5 ? (bc ? "（不透明白）" : "（透明黑）") : "");
                if (bad >= 0) { printf("✗ %s：第 %d 点 (%.3f, %.3f, LOD %.1f) 期望 %.5f 得 %.5f\n", lab, bad, pp[4 * bad], pp[4 * bad + 1], pp[4 * bad + 2], e[bad], g[bad]); fails++; }
                else printf("✓ %s：%d 点与硬件采样逻辑贴图相符\n", lab, NPT);
                if (!diff_neg) { printf("✗ 反证 %s：零表项（不当折行读）也全对上，说明这组位置区分不了折行\n", lab); fails++; }
            }
        }
    }
    return fails ? 1 : 0;
} }
