// t_alpha_ms.py 的 GPU 一侧：① 每个 .metal 编库，main0 / main0_u 各取三种特化（不给常量 / S2A_AT=5 / 再加 S2A_MSOFF=1）都要建得出；
// ② 计算核里跑 FC_DECL 的 s2a_alpha_pass：比较方式 1–8 × (a, r) ∈ {(0.2, 0.5), (0.5, 0.5), (0.8, 0.5)}，24 个结果按行打印（0 / 1），由 t_alpha_ms.py 对手写真值表
// 用法：t_alpha_ms_run <FC_DECL 文件> <.metal>…
#import <Metal/Metal.h>
#include <stdio.h>
int main(int argc, char **argv) { @autoreleasepool {
    if (argc < 2) return 2;
    id<MTLDevice> d = MTLCreateSystemDefaultDevice(); MTLCompileOptions *o = [MTLCompileOptions new]; o.languageVersion = MTLLanguageVersion3_1;
    int ok = 0, bad = 0;
    for (int i = 2; i < argc; i++) {
        NSError *e = nil; id<MTLLibrary> L = [d newLibraryWithSource:[NSString stringWithContentsOfFile:@(argv[i]) encoding:NSUTF8StringEncoding error:nil] options:o error:&e];
        if (!L) { printf("LIB FAIL %s: %s\n", argv[i], e.localizedDescription.UTF8String); bad++; continue; }
        for (NSString *fn in L.functionNames) { if (![fn hasSuffix:@"main0"] && ![fn hasSuffix:@"main0_u"]) continue;
            for (int k = 0; k < 3; k++) { MTLFunctionConstantValues *cv = [MTLFunctionConstantValues new]; int at = 5; bool ms = true;
                if (k >= 1) [cv setConstantValue:&at type:MTLDataTypeInt atIndex:100]; if (k >= 2) [cv setConstantValue:&ms type:MTLDataTypeBool atIndex:101];
                NSError *e2 = nil; if ([L newFunctionWithName:fn constantValues:cv error:&e2]) ok++; else { bad++; printf("FN FAIL %s %s k=%d: %s\n", argv[i], fn.UTF8String, k, e2.localizedDescription.UTF8String); } } } }
    printf("SPEC %d %d\n", ok, bad);
    NSString *decl = [NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:nil];
    NSString *k = [NSString stringWithFormat:@"#include <metal_stdlib>\nusing namespace metal;\n%@\nkernel void t(device uint *o [[buffer(0)]], uint i [[thread_position_in_grid]]) {\n"
        "    const float a[3] = {0.2, 0.5, 0.8}; o[i] = s2a_alpha_pass(int(i / 3) + 1, a[i %% 3], 0.5) ? 1u : 0u;\n}\n", decl];
    NSError *e = nil; id<MTLLibrary> L = [d newLibraryWithSource:k options:o error:&e]; if (!L) { printf("KERNEL FAIL %s\n", e.localizedDescription.UTF8String); return 1; }
    id<MTLComputePipelineState> ps = [d newComputePipelineStateWithFunction:[L newFunctionWithName:@"t"] error:&e];
    id<MTLBuffer> b = [d newBufferWithLength:24 * 4 options:MTLResourceStorageModeShared]; id<MTLCommandQueue> q = [d newCommandQueue];
    id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    [ce setComputePipelineState:ps]; [ce setBuffer:b offset:0 atIndex:0]; [ce dispatchThreads:MTLSizeMake(24, 1, 1) threadsPerThreadgroup:MTLSizeMake(24, 1, 1)]; [ce endEncoding];
    [cb commit]; [cb waitUntilCompleted];
    const uint32_t *r = b.contents; printf("PASS"); for (int i = 0; i < 24; i++) printf(" %u", r[i]); printf("\n");
    return bad != 0;
}}
