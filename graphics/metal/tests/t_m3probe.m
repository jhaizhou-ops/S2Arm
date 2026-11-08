// Metal 3 探针（#108 / M3-1）：离线 MTLBinaryArchive 命中 + 预载动态库管线能否从归档取 + 老接口 CPU 耗时。
// 独立单测：只用老接口（MTLDevice / MTLRenderPipelineDescriptor / MTLBinaryArchive / MTLDynamicLibrary），
//   不经过渲染器、不需要 NXGAL_BE=mtl3（那是 #111 的内容），macOS 27 上照样能跑。
//
// 期望（手算，不跑被测实现）：
//   P1 命中：归档里加入 BGRA8 描述 → 序列化 → 重新载入 → 同描述 + MTLPipelineOptionFailOnBinaryArchiveMiss 建管线 = 非空
//   P1 反证：同一份归档、颜色格式换 RGBA8 → FailOnMiss 建管线 = nil（归档里没有这条，必须报未命中）
//   P2 命中：桩库（MTLCompileOptions.allowReferencingUndefinedSymbols = YES）+ 函数体动态库（libraryType = MTLLibraryTypeDynamic，
//            函数用 extern "C" [[visible]] 导出）按 vertexPreloadedLibraries / fragmentPreloadedLibraries 建管线 = 非空；
//            把这条桩管线也加进归档、重新载入、FailOnMiss 再建 = 非空
//   P2 反证：同归档、桩管线换 RGBA8 → FailOnMiss = nil
//   P4a：1000 次「建命令缓冲 + 提交 + 等完成」的 CPU 耗时中位数（微秒，不含绘制）
//   P4b：1000 次「编码一次绘制 + 提交 + 等完成」的 CPU 耗时中位数（微秒，同一管线）
//
// 离线那一条（P1 的「离线出老格式归档」）在本机 Xcode 27.1 / Metal 27.1 工具链的实测结论：**否 / 未打通**
//   - applegpu-nt -N 只按扩展名认脚本：.mtl4-json 认；.mtl-json / .mtl3-json / .mtlp-json / .mtlscript 一律
//     「cannot load ... unknown file extension」。产物是 Metal 4 的 MTL4Archive（Mach-O，0xfeedfacf），
//     老接口 newBinaryArchiveWithDescriptor: 不能直接当 MTLBinaryArchive 用。
//   - -platform_version macos 15.0 / 18.0 目标 → applegpu-nt 段错误（退出 139）；27.0 才成功。
//   - 工具链里没有 .mtlp-json 管线脚本 / metal-pipelines 入口：metal-tt -h 只有 air→metallib 的翻译选项，
//     bin 目录里没有 pipeline 类工具（metal-package 是 air 打包，不是管线脚本）。
//   所以本单测走退一步对照：运行时 addRenderPipelineFunctionsWithDescriptor + serializeToURL 生成归档，
//   再载入按描述命中 —— 证明「老接口按描述命中」这条机制本身成立。
// 复现离线那条的命令：
//   xcrun -sdk macosx metal -std=metal3.2 -mmacosx-version-min=15.0 -c a.metal -o a.air
//   xcrun -sdk macosx metallib a.air -o gal.0.metallib
//   python3 graphics/tools/shbake/pso_gen.py programs.tsv gal.idx gal.shards pso 300
//   NT=$(dirname "$(xcrun -f metal-tt)")/../metal/current/bin/applegpu-nt
//   "$NT" -arch <MTLDevice.architecture.name> -platform_version macos 27.0 "$(xcrun --sdk macosx --show-sdk-version)" \
//         -sysroot "$(xcrun --sdk macosx --show-sdk-path)" -N pso.0.mtl4-json -o arch.bin
#import <Metal/Metal.h>
#include "fixture.h"
#include <stdio.h>
#include <string.h>
#include <time.h>

static int g_fail, g_checks;
#define CHECK(cond, ...) do { g_checks++; if (!(cond)) { g_fail++; printf("  ✗ " __VA_ARGS__); printf("\n"); } } while (0)

// 顶点 / 片元：整份编（P1 用）
static const char *k_vs =
"#include <metal_stdlib>\nusing namespace metal;\n"
"struct VOut { float4 pos [[position]]; };\n"
"vertex VOut vs_main(uint vid [[vertex_id]]) {\n"
"    VOut o; float2 p = float2(float((vid << 1) & 2u), float(vid & 2u));\n"
"    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0); return o; }\n";
static const char *k_fs =
"#include <metal_stdlib>\nusing namespace metal;\n"
"fragment float4 fs_main(float4 p [[position]]) { return float4(1.0, 0.0, 0.0, 1.0); }\n";

// 函数体（动态库）：普通函数 + extern "C" [[visible]] 才导出成可被桩解析的符号（带 vertex / fragment 属性与 visible 冲突）
static const char *k_body_v =
"#include <metal_stdlib>\nusing namespace metal;\n"
"extern \"C\" [[visible]] float4 s2a_vb(uint vid) {\n"
"    float2 p = float2(float((vid << 1) & 2u), float(vid & 2u)); return float4(p * 2.0 - 1.0, 0.0, 1.0); }\n";
static const char *k_body_f =
"#include <metal_stdlib>\nusing namespace metal;\n"
"extern \"C\" [[visible]] float4 s2a_fb(float4 p) { return float4(1.0, 0.0, 0.0, 1.0); }\n";
// 桩：extern "C" 声明函数体，桩里只做转发
static const char *k_stub =
"#include <metal_stdlib>\nusing namespace metal;\n"
"extern \"C\" float4 s2a_vb(uint vid);\n"
"extern \"C\" float4 s2a_fb(float4 p);\n"
"vertex float4 stub_v(uint vid [[vertex_id]]) { return s2a_vb(vid); }\n"
"fragment float4 stub_f(float4 p [[position]]) { return s2a_fb(p); }\n";

static MTLRenderPipelineDescriptor *desc_of(id<MTLLibrary> lib, MTLPixelFormat fmt) {
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [lib newFunctionWithName:@"vs_main"];
    d.fragmentFunction = [lib newFunctionWithName:@"fs_main"];
    d.colorAttachments[0].pixelFormat = fmt;
    return d;
}

static double now_us(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (double)t.tv_sec * 1e6 + (double)t.tv_nsec / 1e3; }
static int cmp_d(const void *a, const void *b) { double x = *(const double *)a, y = *(const double *)b; return (x > y) - (x < y); }
static double median(double *v, int n) { qsort(v, n, sizeof(double), cmp_d); return v[n / 2]; }

int main(void) {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) { printf("没有 Metal 设备\n"); return 3; }
        printf("设备：%s / 架构：%s / 系统：%s\n", dev.name.UTF8String, dev.architecture.name.UTF8String,
               NSProcessInfo.processInfo.operatingSystemVersionString.UTF8String);

        NSError *e = nil;
        NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"s2a_m3probe_%d", getpid()]];
        [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:@{} error:nil];

        // ---------- P1：归档按描述命中（运行时生成 → 重新载入 → FailOnMiss） ----------
        id<MTLLibrary> lib = [dev newLibraryWithSource:@(k_vs) options:nil error:&e];
        CHECK(lib != nil, "顶点库编不出：%s", e.localizedDescription.UTF8String);
        id<MTLLibrary> flib = [dev newLibraryWithSource:@(k_fs) options:nil error:&e];
        CHECK(flib != nil, "片元库编不出：%s", e.localizedDescription.UTF8String);
        if (!lib || !flib) return 3;
        // 把两支函数塞进同一个库对象不方便，P1 用两段源码合一份编
        NSString *both = [NSString stringWithFormat:@"%s\n%s", k_vs, k_fs];
        id<MTLLibrary> whole = [dev newLibraryWithSource:both options:nil error:&e];
        CHECK(whole != nil, "整份库编不出：%s", e.localizedDescription.UTF8String);
        if (!whole) return 3;

        NSString *p1path = [dir stringByAppendingPathComponent:@"p1.mtlarchive"];
        MTLBinaryArchiveDescriptor *ad = [MTLBinaryArchiveDescriptor new];
        id<MTLBinaryArchive> ar = [dev newBinaryArchiveWithDescriptor:ad error:&e];
        CHECK(ar != nil, "建归档失败：%s", e.localizedDescription.UTF8String);
        BOOL added = ar && [ar addRenderPipelineFunctionsWithDescriptor:desc_of(whole, MTLPixelFormatBGRA8Unorm) error:&e];
        CHECK(added, "归档加入 BGRA8 管线失败：%s", e.localizedDescription.UTF8String);
        BOOL ser = ar && [ar serializeToURL:[NSURL fileURLWithPath:p1path] error:&e];
        CHECK(ser, "归档序列化失败：%s", e.localizedDescription.UTF8String);
        long long sz = [[[NSFileManager defaultManager] attributesOfItemAtPath:p1path error:nil][NSFileSize] longLongValue];
        printf("P1 归档落盘：期望 非空 → 真结果 %lld 字节\n", sz);

        MTLBinaryArchiveDescriptor *readback = [MTLBinaryArchiveDescriptor new];
        readback.url = [NSURL fileURLWithPath:p1path];
        id<MTLBinaryArchive> ar2 = [dev newBinaryArchiveWithDescriptor:readback error:&e];
        CHECK(ar2 != nil, "归档重新载入失败：%s", e.localizedDescription.UTF8String);

        id<MTLRenderPipelineState> hit = nil;
        if (ar2) {
            MTLRenderPipelineDescriptor *d = desc_of(whole, MTLPixelFormatBGRA8Unorm);
            d.binaryArchives = @[ar2];
            hit = [dev newRenderPipelineStateWithDescriptor:d options:MTLPipelineOptionFailOnBinaryArchiveMiss reflection:nil error:&e];
        }
        printf("P1 命中：期望 是 → 真结果 %s\n", hit ? "是" : "否");
        CHECK(hit != nil, "P1 同描述 FailOnMiss 没命中：%s", e ? e.localizedDescription.UTF8String : "-");

        id<MTLRenderPipelineState> miss = nil;
        if (ar2) {
            MTLRenderPipelineDescriptor *d = desc_of(whole, MTLPixelFormatRGBA8Unorm);   // 归档里没有这条
            d.binaryArchives = @[ar2];
            miss = [dev newRenderPipelineStateWithDescriptor:d options:MTLPipelineOptionFailOnBinaryArchiveMiss reflection:nil error:&e];
        }
        printf("P1 反证：期望 否（换 RGBA8 必须未命中）→ 真结果 %s\n", miss ? "命中" : "否");
        CHECK(miss == nil, "P1 反证失败：换颜色格式仍命中");

        // ---------- P2：桩 + 预载函数体动态库，管线能否从归档取 ----------
        MTLCompileOptions *bo = [MTLCompileOptions new];
        bo.libraryType = MTLLibraryTypeDynamic;
        bo.installName = @"@executable_path/s2a_body_v.metallib";
        id<MTLLibrary> bv = [dev newLibraryWithSource:@(k_body_v) options:bo error:&e];
        CHECK(bv != nil, "函数体顶点库编不出：%s", e.localizedDescription.UTF8String);
        MTLCompileOptions *bo2 = [MTLCompileOptions new];
        bo2.libraryType = MTLLibraryTypeDynamic;
        bo2.installName = @"@executable_path/s2a_body_f.metallib";
        id<MTLLibrary> bf = [dev newLibraryWithSource:@(k_body_f) options:bo2 error:&e];
        CHECK(bf != nil, "函数体片元库编不出：%s", e.localizedDescription.UTF8String);
        id<MTLDynamicLibrary> dv = bv ? [dev newDynamicLibrary:bv error:&e] : nil;
        CHECK(dv != nil, "顶点函数体动态库建不出：%s", e.localizedDescription.UTF8String);
        id<MTLDynamicLibrary> df = bf ? [dev newDynamicLibrary:bf error:&e] : nil;
        CHECK(df != nil, "片元函数体动态库建不出：%s", e.localizedDescription.UTF8String);

        MTLCompileOptions *so = [MTLCompileOptions new];
        so.allowReferencingUndefinedSymbols = YES;
        id<MTLLibrary> stub = [dev newLibraryWithSource:@(k_stub) options:so error:&e];
        CHECK(stub != nil, "桩库编不出（allowReferencingUndefinedSymbols）：%s", e.localizedDescription.UTF8String);

        MTLRenderPipelineDescriptor *stubDesc = [MTLRenderPipelineDescriptor new];
        stubDesc.vertexFunction = [stub newFunctionWithName:@"stub_v"];
        stubDesc.fragmentFunction = [stub newFunctionWithName:@"stub_f"];
        stubDesc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        if (dv && df) { stubDesc.vertexPreloadedLibraries = @[dv]; stubDesc.fragmentPreloadedLibraries = @[df]; }
        id<MTLRenderPipelineState> linked = [dev newRenderPipelineStateWithDescriptor:stubDesc options:0 reflection:nil error:&e];
        printf("P2 桩+预载动态库建管线：期望 是 → 真结果 %s\n", linked ? "是" : "否");
        CHECK(linked != nil, "桩管线建不出：%s", e.localizedDescription.UTF8String);

        // 把桩管线也加进归档，重新载入后按描述取
        NSString *p2path = [dir stringByAppendingPathComponent:@"p2.mtlarchive"];
        MTLBinaryArchiveDescriptor *ad2 = [MTLBinaryArchiveDescriptor new];
        id<MTLBinaryArchive> ar3 = [dev newBinaryArchiveWithDescriptor:ad2 error:&e];
        BOOL added2 = ar3 && [ar3 addRenderPipelineFunctionsWithDescriptor:stubDesc error:&e];
        CHECK(added2, "归档加入桩管线失败：%s", e.localizedDescription.UTF8String);
        BOOL ser2 = ar3 && [ar3 serializeToURL:[NSURL fileURLWithPath:p2path] error:&e];
        CHECK(ser2, "桩管线归档序列化失败：%s", e.localizedDescription.UTF8String);

        MTLBinaryArchiveDescriptor *readback2 = [MTLBinaryArchiveDescriptor new];
        readback2.url = [NSURL fileURLWithPath:p2path];
        id<MTLBinaryArchive> ar4 = [dev newBinaryArchiveWithDescriptor:readback2 error:&e];
        id<MTLRenderPipelineState> p2hit = nil;
        if (ar4) {
            MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
            d.vertexFunction = [stub newFunctionWithName:@"stub_v"];
            d.fragmentFunction = [stub newFunctionWithName:@"stub_f"];
            d.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
            if (dv && df) { d.vertexPreloadedLibraries = @[dv]; d.fragmentPreloadedLibraries = @[df]; }
            d.binaryArchives = @[ar4];
            p2hit = [dev newRenderPipelineStateWithDescriptor:d options:MTLPipelineOptionFailOnBinaryArchiveMiss reflection:nil error:&e];
        }
        printf("P2 从归档取桩管线：期望 是 → 真结果 %s\n", p2hit ? "是" : "否");
        CHECK(p2hit != nil, "P2 桩管线从归档没取到：%s", e ? e.localizedDescription.UTF8String : "-");

        id<MTLRenderPipelineState> p2miss = nil;
        if (ar4) {
            MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
            d.vertexFunction = [stub newFunctionWithName:@"stub_v"];
            d.fragmentFunction = [stub newFunctionWithName:@"stub_f"];
            d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;   // 归档里没有这条
            if (dv && df) { d.vertexPreloadedLibraries = @[dv]; d.fragmentPreloadedLibraries = @[df]; }
            d.binaryArchives = @[ar4];
            p2miss = [dev newRenderPipelineStateWithDescriptor:d options:MTLPipelineOptionFailOnBinaryArchiveMiss reflection:nil error:&e];
        }
        printf("P2 反证：期望 否（换 RGBA8 必须未命中）→ 真结果 %s\n", p2miss ? "命中" : "否");
        CHECK(p2miss == nil, "P2 反证失败：换颜色格式仍命中");

        // ---------- P4a / P4b：老接口 CPU 耗时 ----------
        id<MTLCommandQueue> q = [dev newCommandQueue];
        const int N = 1000;
        double *t = malloc(sizeof(double) * N);
        for (int i = 0; i < N; i++) {
            double a = now_us();
            id<MTLCommandBuffer> cb = [q commandBuffer];
            [cb commit]; [cb waitUntilCompleted];
            t[i] = now_us() - a;
        }
        printf("P4a 每帧「建命令缓冲 + 提交 + 等完成」：期望 读数 → 真结果 %.1f us（中位数，%d 次）\n", median(t, N), N);

        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:16 height:16 mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget;
        td.storageMode = MTLStorageModePrivate;
        id<MTLTexture> rt = [dev newTextureWithDescriptor:td];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = rt;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        if (linked) {
            for (int i = 0; i < N; i++) {
                double a = now_us();
                id<MTLCommandBuffer> cb = [q commandBuffer];
                id<MTLRenderCommandEncoder> en = [cb renderCommandEncoderWithDescriptor:rp];
                [en setRenderPipelineState:linked];
                [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                [en endEncoding];
                [cb commit]; [cb waitUntilCompleted];
                t[i] = now_us() - a;
            }
            printf("P4b 每次绘制（编码 + 提交 + 等完成）：期望 读数 → 真结果 %.1f us（中位数，%d 次）\n", median(t, N), N);
        } else {
            printf("P4b 每次绘制：期望 读数 → 真结果 未测（桩管线没建出来）\n");
        }
        free(t);

        [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
        printf("M3 探针（#108）：共 %d 项，失败 %d\n", g_checks, g_fail);
        return g_fail ? 1 : 0;
    }
}