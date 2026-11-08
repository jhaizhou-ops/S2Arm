// 管线归档命中探针（t_pso_cache.sh 用）：archprobe <归档.bin> <metallib> R <顶点函数> <片元函数> | V <顶点函数（只有顶点阶段）> | C <计算函数> …，打印「命中 n/总数」
// S <vs> <fs>：特化完整版（附件 0 RGB10A2 写 R|A、开混合 加 / SrcAlpha / 1-SrcAlpha、alpha Max / One / One；附件 1 RGBA16F；拓扑三角形）；N 同 S 但附件 0 换 BGRA8（对照，应没中）
// 描述与运行时逐字段相同：渲染 = gal_state.m pso_desc(…, unspec=1)（8 个颜色附件全留空、拓扑未指定），计算 = 只有函数；判命中同 gal_core.m（MTL4Archive 按描述查，非空即中）
#import <Metal/Metal.h>
#include <stdio.h>
#include <string.h>
static MTL4LibraryFunctionDescriptor *fd(id<MTLLibrary> l, const char *n) { MTL4LibraryFunctionDescriptor *f = [MTL4LibraryFunctionDescriptor new]; f.library = l; f.name = @(n); return f; }
int main(int argc, char **argv) {
    if (argc < 5) { fprintf(stderr, "用法：archprobe <归档> <metallib> R <vs> <fs> | V <vs> | C <cs> …\n"); return 2; }
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); NSError *e = nil;
        id<MTL4Archive> ar = [dev newArchiveWithURL:[NSURL fileURLWithPath:@(argv[1])] error:&e];
        if (!ar) { printf("归档载入失败：%s\n", e.localizedDescription.UTF8String); return 3; }
        id<MTLLibrary> lib = [dev newLibraryWithURL:[NSURL fileURLWithPath:@(argv[2])] error:&e];
        if (!lib) { printf("库载入失败：%s\n", e.localizedDescription.UTF8String); return 3; }
        int hit = 0, tot = 0;
        for (int i = 3; i < argc; tot++) {
            id p = nil;
            int vo = !strcmp(argv[i], "V");   // V <vs>：只有顶点阶段（片元为空），其余同 R
            if ((!strcmp(argv[i], "R") && i + 2 < argc) || (vo && i + 1 < argc)) {
                MTL4RenderPipelineDescriptor *d = [MTL4RenderPipelineDescriptor new];
                d.vertexFunctionDescriptor = fd(lib, argv[i + 1]); if (!vo) d.fragmentFunctionDescriptor = fd(lib, argv[i + 2]);
                d.rasterizationEnabled = YES; d.rasterSampleCount = 1; d.inputPrimitiveTopology = MTLPrimitiveTopologyClassUnspecified;
                d.alphaToCoverageState = MTL4AlphaToCoverageStateDisabled; d.alphaToOneState = MTL4AlphaToOneStateDisabled;
                for (int c = 0; c < 8; c++) { MTL4RenderPipelineColorAttachmentDescriptor *a = d.colorAttachments[c];
                    a.pixelFormat = MTLPixelFormatUnspecialized; a.blendingState = MTL4BlendStateUnspecialized; a.writeMask = MTLColorWriteMaskUnspecialized;
                    a.sourceRGBBlendFactor = a.destinationRGBBlendFactor = a.sourceAlphaBlendFactor = a.destinationAlphaBlendFactor = MTLBlendFactorUnspecialized;
                    a.rgbBlendOperation = a.alphaBlendOperation = MTLBlendOperationUnspecialized; }
                p = [ar newRenderPipelineStateWithDescriptor:d error:nil]; i += vo ? 2 : 3;
            } else if ((!strcmp(argv[i], "S") || !strcmp(argv[i], "N")) && i + 2 < argc) {
                MTL4RenderPipelineDescriptor *d = [MTL4RenderPipelineDescriptor new];
                d.vertexFunctionDescriptor = fd(lib, argv[i + 1]); d.fragmentFunctionDescriptor = fd(lib, argv[i + 2]);
                d.inputPrimitiveTopology = MTLPrimitiveTopologyClassTriangle;
                MTL4RenderPipelineColorAttachmentDescriptor *a = d.colorAttachments[0];
                a.pixelFormat = !strcmp(argv[i], "S") ? MTLPixelFormatRGB10A2Unorm : MTLPixelFormatBGRA8Unorm; a.writeMask = MTLColorWriteMaskRed | MTLColorWriteMaskAlpha;
                a.blendingState = MTL4BlendStateEnabled; a.rgbBlendOperation = MTLBlendOperationAdd; a.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha; a.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
                a.alphaBlendOperation = MTLBlendOperationMax; a.sourceAlphaBlendFactor = MTLBlendFactorOne; a.destinationAlphaBlendFactor = MTLBlendFactorOne;
                d.colorAttachments[1].pixelFormat = MTLPixelFormatRGBA16Float;
                p = [ar newRenderPipelineStateWithDescriptor:d error:nil]; i += 3;
            } else if (!strcmp(argv[i], "C") && i + 1 < argc) {
                MTL4ComputePipelineDescriptor *d = [MTL4ComputePipelineDescriptor new]; d.computeFunctionDescriptor = fd(lib, argv[i + 1]);
                p = [ar newComputePipelineStateWithDescriptor:d error:nil]; i += 2;
            } else { fprintf(stderr, "参数错：%s\n", argv[i]); return 2; }
            hit += p != nil;
        }
        printf("命中 %d/%d\n", hit, tot);
    }
    return 0;
}
