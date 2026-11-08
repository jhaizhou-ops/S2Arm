// 管线建立代价实测（第 2 步定方案用）：取着色器包里真程序（顶点 + 片元 MSL），量 ① 完整建管线（颜色格式 / 混合全给）
// ② 片元输出留空（MTLPixelFormatUnspecialized / MTL4BlendStateUnspecialized / MTLColorWriteMaskUnspecialized）建基础管线 ③ 从基础管线按 3 组不同格式 / 混合特化。
// 用法：psobench <msl 目录> <programs.tsv> <程序数 N>；前 N 个程序做 ①、后 N 个做 ②③（不同程序，免驱动缓存互相命中）
#import <Metal/Metal.h>
#include <mach/mach_time.h>
#include <stdio.h>
static double ms(uint64_t t0) { static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb); return (mach_absolute_time() - t0) * tb.numer / tb.denom / 1e6; }
static int cmpd(const void *a, const void *b) { double x = *(const double *)a, y = *(const double *)b; return x < y ? -1 : x > y; }
static void stat(const char *what, double *v, int n) { if (!n) { printf("%s：无\n", what); return; } qsort(v, n, sizeof *v, cmpd); double s = 0; for (int i = 0; i < n; i++) s += v[i]; printf("%s：%d 个，中位 %.2f ms，均 %.2f ms，最大 %.2f ms\n", what, n, v[n / 2], s / n, v[n - 1]); }
int main(int argc, char **argv) {
    if (argc != 4) { fprintf(stderr, "用法：psobench <msl 目录> <programs.tsv> <N>\n"); return 2; }
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); NSError *e = nil;
        id<MTL4Compiler> comp = [dev newCompilerWithDescriptor:[MTL4CompilerDescriptor new] error:&e];
        NSString *dir = @(argv[1]); int N = atoi(argv[3]);
        NSArray<NSString *> *lines = [[NSString stringWithContentsOfFile:@(argv[2]) encoding:NSUTF8StringEncoding error:nil] componentsSeparatedByString:@"\n"];
        NSMutableSet *seen = [NSMutableSet set];
        double full[256], base[256], spec[768]; int nf = 0, nb = 0, ns = 0, used = 0, skip = 0;
        MTLPixelFormat fmts[3] = {MTLPixelFormatRGBA8Unorm, MTLPixelFormatRGBA16Float, MTLPixelFormatBGRA8Unorm};
        for (NSString *l in lines) {
            if (used >= 2 * N) break;
            NSArray *f = [l componentsSeparatedByString:@"\t"]; if (f.count < 7 || ![f[2] isEqual:@"ok"] || ![f[3] isEqual:@"graphics"]) continue;
            NSArray *k = [f[6] componentsSeparatedByString:@","]; if (k.count != 2) continue;
            if ([seen containsObject:k[0]] || [seen containsObject:k[1]]) continue;   // 顶点 / 片元都不与已量过的重复：免驱动按函数缓存互相命中
            [seen addObject:k[0]]; [seen addObject:k[1]];
            id<MTLLibrary> lib[2]; MTL4LibraryFunctionDescriptor *fd[2]; int bad = 0;
            for (int s = 0; s < 2; s++) {
                NSString *src = [NSString stringWithContentsOfFile:[dir stringByAppendingFormat:@"/%@.metal", k[s]] encoding:NSUTF8StringEncoding error:nil];
                if (!src) { bad = 1; break; }
                NSRange r = [src rangeOfString:@"GAL_MSL_NP"]; if (r.location != NSNotFound) src = [src substringToIndex:r.location];   // 只取主份
                lib[s] = [dev newLibraryWithSource:src options:nil error:&e]; if (!lib[s]) { bad = 1; break; }
                fd[s] = [MTL4LibraryFunctionDescriptor new]; fd[s].library = lib[s]; fd[s].name = [NSString stringWithFormat:@"s%@", k[s]];
            }
            if (bad) { skip++; continue; }
            id<MTLFunction> vf = [lib[0] newFunctionWithName:fd[0].name]; if (!vf) { skip++; continue; }
            MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
            for (MTLVertexAttribute *a in vf.vertexAttributes) { if (!a.active) continue;
                MTLDataType t = a.attributeType; MTLVertexFormat vfm = (t == MTLDataTypeUInt4 || t == MTLDataTypeUInt3 || t == MTLDataTypeUInt2 || t == MTLDataTypeUInt) ? MTLVertexFormatUInt4 : (t == MTLDataTypeInt4 || t == MTLDataTypeInt3 || t == MTLDataTypeInt2 || t == MTLDataTypeInt) ? MTLVertexFormatInt4 : MTLVertexFormatFloat4;
                vd.attributes[a.attributeIndex].format = vfm; vd.attributes[a.attributeIndex].bufferIndex = 30; vd.attributes[a.attributeIndex].offset = 0; }
            vd.layouts[30].stride = 16;
            int doFull = used < N; used++;
            MTL4RenderPipelineDescriptor *d = [MTL4RenderPipelineDescriptor new];
            d.vertexFunctionDescriptor = fd[0]; d.fragmentFunctionDescriptor = fd[1]; d.vertexDescriptor = vd; d.inputPrimitiveTopology = MTLPrimitiveTopologyClassUnspecified;   // 写点大小的顶点着色器只接受 Point / Unspecified（同 gal_state.m）
            for (int i = 0; i < 4; i++) {
                MTL4RenderPipelineColorAttachmentDescriptor *c = d.colorAttachments[i];
                if (doFull) { c.pixelFormat = MTLPixelFormatRGBA8Unorm; c.blendingState = MTL4BlendStateEnabled; c.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha; c.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha; c.writeMask = MTLColorWriteMaskAll; }
                else { c.pixelFormat = MTLPixelFormatUnspecialized; c.blendingState = MTL4BlendStateUnspecialized; c.writeMask = MTLColorWriteMaskUnspecialized;
                       c.sourceRGBBlendFactor = c.destinationRGBBlendFactor = c.sourceAlphaBlendFactor = c.destinationAlphaBlendFactor = MTLBlendFactorUnspecialized; c.rgbBlendOperation = c.alphaBlendOperation = MTLBlendOperationUnspecialized; }
            }
            uint64_t t0 = mach_absolute_time();
            id<MTLRenderPipelineState> p = [comp newRenderPipelineStateWithDescriptor:d compilerTaskOptions:nil error:&e];
            double t = ms(t0);
            if (!p) { if (skip++ < 3) fprintf(stderr, "建不出（%s）：%s\n", doFull ? "完整" : "留空", e.localizedDescription.UTF8String); continue; }
            if (doFull) { full[nf++] = t; continue; }
            base[nb++] = t;
            for (int v = 0; v < 3; v++) {
                MTL4RenderPipelineDescriptor *s2 = [d copy];
                for (int i = 0; i < 4; i++) { MTL4RenderPipelineColorAttachmentDescriptor *c = s2.colorAttachments[i];
                    c.pixelFormat = fmts[v]; c.writeMask = MTLColorWriteMaskAll; c.blendingState = v ? MTL4BlendStateEnabled : MTL4BlendStateDisabled;
                    c.sourceRGBBlendFactor = c.sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha; c.destinationRGBBlendFactor = c.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
                    c.rgbBlendOperation = c.alphaBlendOperation = MTLBlendOperationAdd; }
                t0 = mach_absolute_time();
                id<MTLRenderPipelineState> q = [comp newRenderPipelineStateBySpecializationWithDescriptor:s2 pipeline:p error:&e];
                double ts = ms(t0);
                if (q) spec[ns++] = ts; else if (skip++ < 6) fprintf(stderr, "特化失败：%s\n", e.localizedDescription.UTF8String);
            }
        }
        printf("设备 %s；跳过 %d\n", dev.name.UTF8String, skip);
        stat("① 完整建管线", full, nf); stat("② 片元输出留空的基础管线", base, nb); stat("③ 从基础管线特化", spec, ns);
    }
    return 0;
}
