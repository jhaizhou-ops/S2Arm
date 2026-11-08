// 采样器两项 Metal 26 能力在本机 GPU 上原生可用没有（#800）。直连（graphics/nvn/gfx/nvn/nvn_mtl.m）与通用（gal_tex.m）共用这一份判法：
//   min / max 归约（MTLSamplerDescriptor.reductionMode）：Metal Feature Set Tables（2026-05）标 Apple10（A19 / M5）起；10-28 同一探针实测 M5 Max 生效，
//     mini M4 Pro、Air M3（都是 Apple9，系统 27）静默忽略（min / max 都读成普通线性）→ 按家族判。
//   LOD 偏置（MTLSamplerDescriptor.lodBias）：表也写 Apple10 起，但实测 M4 Pro（Apple9）生效、M3（Apple9）忽略 → 按家族判不准，第一次问到时在本机 GPU 上实测一次。
//   不原生可用的那项两条路径都在着色器里做（直连：绘制真绑了这样的采样器时用设备上现出的模拟变体 <键>_se（translator/dmsh_red.py fs_red / S2A.Dsh FsRed，
//   function constant 特化）+ nvn_red.h 表，离线库不带；通用：gal_border.m 采样辅助 + 边框表里的偏置），画面同原生。
//   S2A_SAMP_EMU=1：两项都当不可用，Apple10 本机上走模拟路径（单测 / 对照用）。系统早于 26（没有这两个属性）两项都不可用
#pragma once
#import <Metal/Metal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static inline int s2a_samp_emu_forced(void) { const char *e = getenv("S2A_SAMP_EMU"); return e && !strcmp(e, "1"); }
// min / max 归约原生可用：系统 26 起且 Apple10 GPU，且没有强制模拟
static inline int s2a_reduce_native(id<MTLDevice> dev) {
    if (s2a_samp_emu_forced()) return 0;
    if (@available(macOS 26.0, iOS 26.0, *)) return [dev supportsFamily:MTLGPUFamilyApple10];
    return 0;
}
// LOD 偏置原生可用：系统 26 起、没有强制模拟，且本机 GPU 实测生效——R32Float 4×4 两级 mip（第 0 级 0、第 1 级 1），最近点采样、偏置 1，在 LOD 0 处读，读到 1 = 生效。
//   结果按进程记一次（每个包含它的编译单元各问一次）
static int s2a_lodbias_native(id<MTLDevice> dev) {
    static int v = -1; if (v >= 0) return v;
    v = 0;
    if (s2a_samp_emu_forced()) { fprintf(stderr, "[s2a] 采样器 LOD 偏置：S2A_SAMP_EMU=1，按不生效走着色器模拟\n"); return v; }
    if (@available(macOS 26.0, iOS 26.0, *)) { @autoreleasepool {
        NSError *e = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\nkernel void k(texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], device float *o [[buffer(0)]]) { o[0] = t.sample(s, float2(0.5), level(0.0)).r; }\n" options:nil error:&e];
        id<MTLComputePipelineState> ps = lib ? [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&e] : nil;
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float width:4 height:4 mipmapped:YES]; td.storageMode = MTLStorageModeShared;
        id<MTLTexture> t = [dev newTextureWithDescriptor:td]; float z[16] = {0}, one[4] = {1, 1, 1, 1};
        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new]; sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterNearest; sd.mipFilter = MTLSamplerMipFilterNearest; sd.lodBias = 1.0f;
        id<MTLSamplerState> ss = [dev newSamplerStateWithDescriptor:sd]; id<MTLBuffer> ob = [dev newBufferWithLength:4 options:MTLResourceStorageModeShared];
        id<MTLCommandQueue> q = [dev newCommandQueue];
        if (ps && t && ss && ob && q) {
            [t replaceRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0 withBytes:z bytesPerRow:16]; [t replaceRegion:MTLRegionMake2D(0, 0, 2, 2) mipmapLevel:1 withBytes:one bytesPerRow:8];
            id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> en = [cb computeCommandEncoder];
            [en setComputePipelineState:ps]; [en setTexture:t atIndex:0]; [en setSamplerState:ss atIndex:0]; [en setBuffer:ob offset:0 atIndex:0];
            [en dispatchThreads:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)]; [en endEncoding]; [cb commit]; [cb waitUntilCompleted];
            v = ((float *)ob.contents)[0] == 1.0f;
        }
        fprintf(stderr, "[s2a] 采样器 LOD 偏置实测：%s（%s）%s\n", v ? "生效" : "不生效", dev.name.UTF8String, v ? "" : "，走着色器模拟");
    } }
    return v;
}
