// 静态配对定方案用（10-20）：Metal 建管线有没有「按阶段复用」。取着色器包里真程序的顶点 / 片元 MSL（阶段独立翻译：顶点写全部 32 个通用输出），
// 建片元输出留空的基础管线（同 gal_state.m unspec），量三种情况：
//   ① 新：(vs_i, ps_i) 两个阶段都第一次进管线
//   ② 交叉：(vs_i, ps_{i+1})，两个阶段都已在 ① 里编过（若驱动按阶段缓存，应远小于 ①）
//   ③ 半新：(vs_i, ps_new)，顶点编过、片元第一次
// 另报交叉组合能否全部建成（任意 vs × ps 链接是否成立）。用法：pairbench <msl 目录> <programs.tsv> <N>
#import <Metal/Metal.h>
#include <mach/mach_time.h>
#include <stdio.h>
static double ms(uint64_t t0) { static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb); return (mach_absolute_time() - t0) * tb.numer / tb.denom / 1e6; }
static int cmpd(const void *a, const void *b) { double x = *(const double *)a, y = *(const double *)b; return x < y ? -1 : x > y; }
static void stat(const char *what, double *v, int n) { if (!n) { printf("%s：无\n", what); return; } qsort(v, n, sizeof *v, cmpd); double s = 0; for (int i = 0; i < n; i++) s += v[i]; printf("%s：%d 个，中位 %.2f ms，均 %.2f ms，最大 %.2f ms\n", what, n, v[n / 2], s / n, v[n - 1]); }

static MTL4LibraryFunctionDescriptor *load(id<MTLDevice> dev, NSString *dir, NSString *key) {
    NSError *e = nil;
    NSString *src = [NSString stringWithContentsOfFile:[dir stringByAppendingFormat:@"/%@.metal", key] encoding:NSUTF8StringEncoding error:nil];
    if (!src) return nil;
    NSRange r = [src rangeOfString:@"GAL_MSL_NP"]; if (r.location != NSNotFound) src = [src substringToIndex:r.location];
    id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&e]; if (!lib) return nil;
    MTL4LibraryFunctionDescriptor *fd = [MTL4LibraryFunctionDescriptor new]; fd.library = lib; fd.name = [NSString stringWithFormat:@"s%@", key];
    return [lib newFunctionWithName:fd.name] ? fd : nil;
}

static id<MTLRenderPipelineState> build(id<MTL4Compiler> comp, MTL4LibraryFunctionDescriptor *vs, MTL4LibraryFunctionDescriptor *ps, double *t, NSString **err) {
    MTL4RenderPipelineDescriptor *d = [MTL4RenderPipelineDescriptor new];
    d.vertexFunctionDescriptor = vs; d.fragmentFunctionDescriptor = ps; d.inputPrimitiveTopology = MTLPrimitiveTopologyClassUnspecified;
    MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];   // 顶点自取的着色器没有属性；没自取的按 16 字节 float4 喂（同 psobench）
    id<MTLFunction> vf = [vs.library newFunctionWithName:vs.name];
    for (MTLVertexAttribute *a in vf.vertexAttributes) { if (!a.active) continue;
        MTLDataType ty = a.attributeType; MTLVertexFormat f = (ty == MTLDataTypeUInt4 || ty == MTLDataTypeUInt3 || ty == MTLDataTypeUInt2 || ty == MTLDataTypeUInt) ? MTLVertexFormatUInt4 : (ty == MTLDataTypeInt4 || ty == MTLDataTypeInt3 || ty == MTLDataTypeInt2 || ty == MTLDataTypeInt) ? MTLVertexFormatInt4 : MTLVertexFormatFloat4;
        vd.attributes[a.attributeIndex].format = f; vd.attributes[a.attributeIndex].bufferIndex = 30; vd.attributes[a.attributeIndex].offset = 0; vd.layouts[30].stride = 16; }
    d.vertexDescriptor = vd;
    for (int i = 0; i < 8; i++) { MTL4RenderPipelineColorAttachmentDescriptor *c = d.colorAttachments[i];
        c.pixelFormat = MTLPixelFormatUnspecialized; c.blendingState = MTL4BlendStateUnspecialized; c.writeMask = MTLColorWriteMaskUnspecialized;
        c.sourceRGBBlendFactor = c.destinationRGBBlendFactor = c.sourceAlphaBlendFactor = c.destinationAlphaBlendFactor = MTLBlendFactorUnspecialized; c.rgbBlendOperation = c.alphaBlendOperation = MTLBlendOperationUnspecialized; }
    NSError *e = nil; uint64_t t0 = mach_absolute_time();
    id<MTLRenderPipelineState> p = [comp newRenderPipelineStateWithDescriptor:d compilerTaskOptions:nil error:&e];
    *t = ms(t0); if (!p && err) *err = e.localizedDescription;
    return p;
}

int main(int argc, char **argv) {
    if (argc != 4) { fprintf(stderr, "用法：pairbench <msl 目录> <programs.tsv> <N>\n"); return 2; }
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); NSError *e = nil;
        id<MTL4Compiler> comp = [dev newCompilerWithDescriptor:[MTL4CompilerDescriptor new] error:&e];
        NSString *dir = @(argv[1]); int N = atoi(argv[3]); if (N > 200) N = 200;
        NSArray<NSString *> *lines = [[NSString stringWithContentsOfFile:@(argv[2]) encoding:NSUTF8StringEncoding error:nil] componentsSeparatedByString:@"\n"];
        NSMutableSet *seen = [NSMutableSet set];
        MTL4LibraryFunctionDescriptor *V[201], *F[201], *Fnew[201]; int n = 0, nn = 0;
        for (NSString *l in lines) {   // 顶点 / 片元都不重复的程序：前 N 个做 ① ②，再 N 个只取片元做 ③
            if (nn >= N) break;
            NSArray *f = [l componentsSeparatedByString:@"\t"]; if (f.count < 7 || ![f[2] isEqual:@"ok"] || ![f[3] isEqual:@"graphics"]) continue;
            NSArray *k = [f[6] componentsSeparatedByString:@","]; if (k.count != 2 || [seen containsObject:k[0]] || [seen containsObject:k[1]]) continue;
            MTL4LibraryFunctionDescriptor *a = load(dev, dir, k[0]), *b = load(dev, dir, k[1]); if (!a || !b) continue;
            [seen addObject:k[0]]; [seen addObject:k[1]];
            if (n < N) { V[n] = a; F[n] = b; n++; } else Fnew[nn++] = b;
        }
        double t1[200], t2[200], t3[200]; int n1 = 0, n2 = 0, n3 = 0, bad2 = 0; double t;
        NSString *err = nil;
        for (int i = 0; i < n; i++) if (build(comp, V[i], F[i], &t, &err)) t1[n1++] = t;
        for (int i = 0; i < n; i++) { err = nil; if (build(comp, V[i], F[(i + 1) % n], &t, &err)) t2[n2++] = t; else if (bad2++ < 3) fprintf(stderr, "交叉建不出：%s\n", err.UTF8String); }
        for (int i = 0; i < nn && i < n; i++) if (build(comp, V[i], Fnew[i], &t, &err)) t3[n3++] = t;
        printf("设备 %s；程序 %d（另取新片元 %d）；交叉建不出 %d\n", dev.name.UTF8String, n, nn, bad2);
        stat("① 新（两阶段都首次）", t1, n1); stat("② 交叉（两阶段都编过）", t2, n2); stat("③ 半新（顶点编过、片元首次）", t3, n3);
    }
    return 0;
}
