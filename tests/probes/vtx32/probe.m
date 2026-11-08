// 方案 5b-5 真机探针：顶点着色器声明全部 32 个通用输出（分阶段独立翻译的代价）vs 只输出实际用到的 4 个，同场景比每帧 GPU 时间。
// 变体：A = 顶点 4 输出 / 片元读 4；B = 顶点 32 输出 / 片元声明并读 4；C = 顶点 32 输出 / 片元声明 32 读 4（片元按「全部通用输入合并」的形态）；
// D = 顶点 32 输出 / 片元读 30（正对照，32 全读超片元输入 124 分量上限：证明测量对输出个数有灵敏度，B≈A 才能归因于管线链接时裁掉没用到的输出）。
// 每个输出各自算（含顶点号与输出号，编译器合并不了）；场景 = 离屏 1920×1080 BGRA8 + 深度，按顶点号生成的网格（不读顶点缓冲，排除输入带宽）。
// 两档密度：密 600×600 格（72 万三角形）、中 220×220 格（约 10 万三角形）。每档 A/B/C 轮流跑 3 轮，每轮每变体先热 20 帧再采 120 帧，
// 每帧一个命令缓冲、等完成，取 GPUEndTime − GPUStartTime。结果打到标准输出（devicectl --console 收），跑完 exit(0)。
#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#include <stdio.h>
#include <stdlib.h>

static NSString *src(int nout, int fin, int fread) {
    NSMutableString *s = [NSMutableString stringWithString:@"#include <metal_stdlib>\nusing namespace metal;\nstruct VO { float4 pos [[position]];\n"];
    for (int i = 0; i < nout; i++) [s appendFormat:@" float4 v%d [[user(locn%d)]];\n", i, i];
    [s appendString:@"};\nstruct FI { float4 pos [[position]];\n"];
    for (int i = 0; i < fin; i++) [s appendFormat:@" float4 v%d [[user(locn%d)]];\n", i, i];
    [s appendString:@"};\nvertex VO vs(uint vid [[vertex_id]], constant uint &G [[buffer(0)]], constant float &T [[buffer(1)]]) {\n"
                    " uint q = vid / 6u, c = vid % 6u; uint x = q % G, y = q / G;\n"
                    " const uint2 o[6] = { uint2(0,0), uint2(1,0), uint2(0,1), uint2(1,0), uint2(1,1), uint2(0,1) };\n"
                    " float2 p = (float2(x + o[c].x, y + o[c].y) / float(G)) * 2.0 - 1.0;\n"
                    " VO r; r.pos = float4(p, fract(float(vid) * 1e-7), 1.0); float f = float(vid);\n"];
    for (int i = 0; i < nout; i++) [s appendFormat:@" r.v%d = float4(sin(f * %d.013 + T), cos(p.x * %d.7), p.y * %d.0 + T, fract(f * 0.0%d1));\n", i, i + 1, i + 1, i + 1, i + 1];
    [s appendString:@" return r; }\nfragment float4 fs(FI in [[stage_in]]) { float4 a = 0;\n"];
    for (int i = 0; i < fread; i++) [s appendFormat:@" a += in.v%d;\n", i];
    [s appendFormat:@" return saturate(a * %f); }\n", 1.0 / fread];
    return s;
}

static id<MTLRenderPipelineState> mkpipe(id<MTLDevice> d, int nout, int fin, int fread) {
    NSError *e = nil; MTLCompileOptions *o = [MTLCompileOptions new];
    id<MTLLibrary> lib = [d newLibraryWithSource:src(nout, fin, fread) options:o error:&e];
    if (!lib) { printf("编译失败 %d/%d：%s\n", nout, fin, e.localizedDescription.UTF8String); exit(2); }
    MTLRenderPipelineDescriptor *p = [MTLRenderPipelineDescriptor new];
    p.vertexFunction = [lib newFunctionWithName:@"vs"]; p.fragmentFunction = [lib newFunctionWithName:@"fs"];
    p.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm; p.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
    id<MTLRenderPipelineState> ps = [d newRenderPipelineStateWithDescriptor:p error:&e];
    if (!ps) { printf("管线失败 %d/%d：%s\n", nout, fin, e.localizedDescription.UTF8String); exit(2); }
    return ps;
}

static int cmpd(const void *a, const void *b) { double x = *(const double *)a, y = *(const double *)b; return x < y ? -1 : x > y; }

static void bench(void) {
    id<MTLDevice> d = MTLCreateSystemDefaultDevice(); id<MTLCommandQueue> q = [d newCommandQueue];
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:1920 height:1080 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModePrivate; id<MTLTexture> rt = [d newTextureWithDescriptor:td];
    MTLTextureDescriptor *dd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:1920 height:1080 mipmapped:NO];
    dd.usage = MTLTextureUsageRenderTarget; dd.storageMode = MTLStorageModeMemoryless; id<MTLTexture> dt = [d newTextureWithDescriptor:dd];
    id<MTLDepthStencilState> ds; { MTLDepthStencilDescriptor *x = [MTLDepthStencilDescriptor new]; x.depthCompareFunction = MTLCompareFunctionLessEqual; x.depthWriteEnabled = YES; ds = [d newDepthStencilStateWithDescriptor:x]; }
    enum { NV = 4 };
    const char *nm[NV] = {"A 4出/4入读4", "B 32出/4入读4", "C 32出/32入读4", "D 32出/30入读30（正对照）"}; int vo[NV] = {4, 32, 32, 32}, fi[NV] = {4, 4, 32, 30}, fr[NV] = {4, 4, 4, 30};   // 32 个全读 = 128 分量，超 Apple GPU 片元输入上限 124，管线编不出（实测 XPC 编译服务中断）
    id<MTLRenderPipelineState> ps[NV]; for (int v = 0; v < NV; v++) ps[v] = mkpipe(d, vo[v], fi[v], fr[v]);
    printf("设备 %s；离屏 1920x1080；每变体每轮 热 20 帧 + 采 120 帧，3 轮轮流\n", d.name.UTF8String);
    uint grids[2] = {600, 220}; const char *gn[2] = {"密（72 万三角形）", "中（约 10 万三角形）"};
    for (int g = 0; g < 2; g++) {
        static double all[NV][360]; int n[NV] = {0};
        for (int round = 0; round < 3; round++) for (int v = 0; v < NV; v++) {
            for (int f = 0; f < 140; f++) @autoreleasepool {
                MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
                rp.colorAttachments[0].texture = rt; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
                rp.depthAttachment.texture = dt; rp.depthAttachment.loadAction = MTLLoadActionClear; rp.depthAttachment.storeAction = MTLStoreActionDontCare; rp.depthAttachment.clearDepth = 1.0;
                id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLRenderCommandEncoder> en = [cb renderCommandEncoderWithDescriptor:rp];
                [en setRenderPipelineState:ps[v]]; [en setDepthStencilState:ds];
                uint G = grids[g]; float T = f * 0.01f; [en setVertexBytes:&G length:4 atIndex:0]; [en setVertexBytes:&T length:4 atIndex:1];
                [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:G * G * 6];
                [en endEncoding]; [cb commit]; [cb waitUntilCompleted];
                if (cb.error) { printf("命令缓冲出错：%s\n", cb.error.localizedDescription.UTF8String); exit(3); }
                if (f >= 20) all[v][n[v]++] = (cb.GPUEndTime - cb.GPUStartTime) * 1000.0;
            }
        }
        printf("== %s\n", gn[g]); double medA = 0;
        for (int v = 0; v < NV; v++) {
            double s = 0; for (int i = 0; i < n[v]; i++) s += all[v][i];
            qsort(all[v], n[v], sizeof(double), cmpd); double med = all[v][n[v] / 2], p90 = all[v][n[v] * 9 / 10];
            if (v == 0) medA = med;
            printf("%s：中位 %.3f ms，均值 %.3f ms，P90 %.3f ms，%d 帧；相对 A %+.1f%%\n", nm[v], med, s / n[v], p90, n[v], (med / medA - 1) * 100);
        }
    }
    printf("探针结束\n"); fflush(stdout);
}

@interface AD : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end
@implementation AD
- (BOOL)application:(UIApplication *)a didFinishLaunchingWithOptions:(NSDictionary *)o {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds]; self.window.rootViewController = [UIViewController new]; [self.window makeKeyAndVisible];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{ bench(); exit(0); });
    return YES;
}
@end
int main(int argc, char **argv) { @autoreleasepool { setvbuf(stdout, NULL, _IOLBF, 0); return UIApplicationMain(argc, argv, nil, NSStringFromClass(AD.class)); } }
