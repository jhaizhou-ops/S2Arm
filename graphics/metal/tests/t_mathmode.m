// 通用路径翻译后着色器的编译选项（#807）：gal_msl_opts（gal_prog.m 运行时现编用的那一份）编出的着色器保留 NaN 判断。
// Ryujinx 翻译对 FSET / FSETP 的无序比较生成 isnan 选择复现 Maxwell 的 NaN 语义；Metal 缺省 fast 数学模式下编译器假设没有 NaN，isnan 恒假。
// 期望（手算，不跑被测实现）：输入 x = NaN、y = 1（缓冲里给，编译期不可知）
//   判据 6 项（relaxed 保证不假设没有 NaN）：o[0] isnan(x) → 1；o[1] select(2, 3, isnan(x * y)) → 3；o[2] isunordered(x, y) → 1；
//     o[3] isnan(x * 0) → 1；o[5] isnan(x - x) → 1；o[7] isnan(fma(x, 0, 1)) → 1
//   只打印不判 2 项：o[4] 0 < abs(x) → 0、o[6] x == x → 0。10-28 本机 M5 / macOS 27 实测 relaxed 下这两项仍被折叠成 1，safe 才对
//     （同 KosmicKrisp KK_WORKAROUND_17；直连 dm_msl_opts 同为 relaxed，同样残留，另立后续项，不在 #807 范围）
// 反证：同一段源码用 [MTLCompileOptions new]（fast，#807 修前通用路径的选项）编，判据 6 项里至少一项被折叠——
//   本机编译器不折叠的话这支单测分辨不了修前修后，判红（判据不许绿着失效）。10-28 本机实测 fast 折叠 o[3] / o[5]。
#import <Metal/Metal.h>
#include <stdio.h>
#include <math.h>
#include "../gal_internal.h"

static const char *k_src =
    "#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void k(device const float *i [[buffer(0)]], device float *o [[buffer(1)]]) {\n"
    "  float x = i[0], y = i[1];\n"
    "  o[0] = isnan(x) ? 1.0 : 0.0;\n"
    "  o[1] = select(2.0, 3.0, isnan(x * y));\n"
    "  o[2] = isunordered(x, y) ? 1.0 : 0.0;\n"
    "  o[3] = isnan(x * 0.0) ? 1.0 : 0.0;\n"
    "  o[4] = (0.0 < abs(x)) ? 1.0 : 0.0;\n"
    "  o[5] = isnan(x - x) ? 1.0 : 0.0;\n"
    "  o[6] = (x == x) ? 1.0 : 0.0;\n"
    "  o[7] = isnan(fma(x, 0.0, 1.0)) ? 1.0 : 0.0; }\n";

static int run(id<MTLDevice> dev, MTLCompileOptions *opt, float out[8]) {
    NSError *e = nil; id<MTLLibrary> lib = [dev newLibraryWithSource:@(k_src) options:opt error:&e];
    if (!lib) { printf("✗ 编译失败：%s\n", e.localizedDescription.UTF8String); return 0; }
    id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&e];
    if (!ps) { printf("✗ 建管线失败：%s\n", e.localizedDescription.UTF8String); return 0; }
    float in[2] = {NAN, 1.0f};
    id<MTLBuffer> bi = [dev newBufferWithBytes:in length:sizeof in options:MTLResourceStorageModeShared];
    id<MTLBuffer> bo = [dev newBufferWithLength:8 * sizeof(float) options:MTLResourceStorageModeShared];
    id<MTLCommandQueue> q = [dev newCommandQueue]; id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    [ce setComputePipelineState:ps]; [ce setBuffer:bi offset:0 atIndex:0]; [ce setBuffer:bo offset:0 atIndex:1];
    [ce dispatchThreads:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)]; [ce endEncoding];
    [cb commit]; [cb waitUntilCompleted];
    memcpy(out, bo.contents, 8 * sizeof(float)); return 1;
}

int main(void) {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); if (!dev) { printf("✗ t_mathmode：没有 Metal 设备\n"); return 1; }
        int bad = 0; float a[8], f[8];
        if (!run(dev, gal_msl_opts(), a) || !run(dev, [MTLCompileOptions new], f)) return 1;
        const float want[8] = {1, 3, 1, 1, 0, 1, 0, 1};
        static const int judged[6] = {0, 1, 2, 3, 5, 7};
        int folded = 0;
        for (int j = 0; j < 6; j++) { int i = judged[j];
            if (a[i] != want[i]) { printf("✗ gal_msl_opts 第 %d 项：期望 %g，实得 %g（NaN 判断被折叠）\n", i, want[i], a[i]); bad++; }
            folded += f[i] != want[i]; }
        printf("· 有序比较（只打印）：0 < abs(NaN) 实得 %g、NaN == NaN 实得 %g（期望都是 0；relaxed 下编译器仍可能折叠，见文件头）\n", a[4], a[6]);
        if (!folded) { printf("✗ 反证不成立：fast 选项下各项也都保留了 NaN 判断，本单测分辨不了 #807 修前修后\n"); bad++; }
        printf("%s t_mathmode：gal_msl_opts %g %g %g %g %g %g %g %g（期望 1 3 1 1 0 1 0 1）；fast 对照 %g %g %g %g %g %g %g %g（判据项里 %d 项被折叠）\n", bad ? "✗" : "✓", a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], f[0], f[1], f[2], f[3], f[4], f[5], f[6], f[7], folded);
        return bad != 0;
    }
}
