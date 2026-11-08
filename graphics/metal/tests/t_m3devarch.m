// Metal 3 归档命中单测（#116 / M3-9 第二批）：设备归档（运行时写盘 → 重开 → 按描述命中）+ 出包归档（metal-tt 编的 .bin）。
// 只用老接口（MTLDevice / MTLRenderPipelineDescriptor / MTLBinaryArchive），不经过渲染器、不需要 NXGAL_BE=mtl3，
//   macOS 27 上照样跑；Metal 3 渲染器自己的归档接缝要等 M3-8（#115，pso_desc 现在建的是 MTL4 描述）。
//
// 期望（手算，不跑被测实现）：
//   A 设备归档：归档 = newBinaryArchiveWithDescriptor（无 URL）+ addRenderPipelineFunctionsWithDescriptor + serializeToURL 写盘
//     A1 写盘字节数 > 0
//     A2 重新打开（url）→ 同一份完整描述（BGRA8 + 写掩码全开 + 混合开 + 附件 1 RGBA16F）+ FailOnBinaryArchiveMiss 建管线 = 非空
//     A3 反证 附件 0 格式 BGRA8 → RGBA8（其余逐字段不变）= nil（归档里没有这条）
//     A4 反证 附件 0 写掩码 全开 → 红|绿（其余不变）= nil
//     A5 计算管线（同一个归档里）按描述 + FailOnMiss = 非空
//   B 出包归档（argv 给了 --pack <归档> <metallib> <顶点函数> <片元函数> 才跑）：
//     B1 归档载入 = 非空
//     B2 pso_gen 出的基础管线描述（8 个颜色附件全 Invalid，其余缺省）+ FailOnMiss = 命中
//     B3 反证 附件 0 换 BGRA8 = 未命中
//
// 为什么是「运行时生成 → 重开」而不是离线读回：本机 Xcode 27.1 的 applegpu-nt 只按扩展名认管线脚本，
//   .mtlp-json 交给 metal-tt（见 graphics/tools/shbake/pso_chunk.sh 的 Metal 3 分支）；设备归档这条（老接口自己收二进制）只能运行时建，
//   两者都按「函数 + 描述」命中，B 段验的就是出包那一份。
#import <Metal/Metal.h>
#include "fixture.h"
#include <stdio.h>
#include <string.h>

static int g_fail, g_checks;
#define CHECK(cond, ...) do { g_checks++; if (!(cond)) { g_fail++; printf("  ✗ " __VA_ARGS__); printf("\n"); } } while (0)

static const char *k_src =
"#include <metal_stdlib>\nusing namespace metal;\n"
"struct VOut { float4 pos [[position]]; };\n"
"vertex VOut vs_main(uint vid [[vertex_id]]) {\n"
"    VOut o; float2 p = float2(float((vid << 1) & 2u), float(vid & 2u));\n"
"    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0); return o; }\n"
"fragment float4 fs_main(float4 p [[position]]) { return float4(1.0, 0.0, 0.0, 1.0); }\n"
"kernel void cs_main(device float4 *b [[buffer(0)]], uint i [[thread_position_in_grid]]) { b[i] += 1.0; }\n";

// 完整描述：默认 BGRA8 + 写掩码全开；换格式 / 换掩码由调用方给（反证只差一个字段）
static MTLRenderPipelineDescriptor *full_desc(id<MTLLibrary> lib, MTLPixelFormat f0, MTLColorWriteMask m0) {
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [lib newFunctionWithName:@"vs_main"];
    d.fragmentFunction = [lib newFunctionWithName:@"fs_main"];
    d.colorAttachments[0].pixelFormat = f0;
    d.colorAttachments[0].writeMask = m0;
    d.colorAttachments[0].blendingEnabled = YES;
    d.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
    d.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    d.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    d.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
    d.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    d.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    d.colorAttachments[1].pixelFormat = MTLPixelFormatRGBA16Float;
    return d;
}

// 错误信息只留第一行：Metal 的未命中报错带整段 <MTLBinaryKey> 转储，多行会把读数刷掉
static const char *head(const NSString *s) {
    if (!s.length) return "无错误信息";
    return [[s componentsSeparatedByString:@"\n"].firstObject UTF8String];
}

static id try_render(id<MTLDevice> dev, id<MTLBinaryArchive> ar, MTLRenderPipelineDescriptor *d, NSString **err) {
    d.binaryArchives = @[ar];
    NSError *e = nil;
    id p = [dev newRenderPipelineStateWithDescriptor:d options:MTLPipelineOptionFailOnBinaryArchiveMiss reflection:nil error:&e];
    if (err) *err = e.localizedDescription;
    return p;
}

static id try_compute(id<MTLDevice> dev, id<MTLBinaryArchive> ar, id<MTLFunction> fn, NSString **err) {
    MTLComputePipelineDescriptor *d = [MTLComputePipelineDescriptor new];
    d.computeFunction = fn;
    d.binaryArchives = @[ar];
    NSError *e = nil;
    id p = [dev newComputePipelineStateWithDescriptor:d options:MTLPipelineOptionFailOnBinaryArchiveMiss reflection:nil error:&e];
    if (err) *err = e.localizedDescription;
    return p;
}

// ---------- A 设备归档 ----------
static void dev_archive(id<MTLDevice> dev, id<MTLLibrary> lib, NSString *dir) {
    NSError *e = nil;
    NSString *path = [dir stringByAppendingPathComponent:@"dev.mtlarchive"];
    id<MTLBinaryArchive> ar = [dev newBinaryArchiveWithDescriptor:[MTLBinaryArchiveDescriptor new] error:&e];
    CHECK(ar != nil, "A 建空归档失败：%s", e.localizedDescription.UTF8String);
    if (!ar) return;
    BOOL added = [ar addRenderPipelineFunctionsWithDescriptor:full_desc(lib, MTLPixelFormatBGRA8Unorm, MTLColorWriteMaskAll) error:&e];
    CHECK(added, "A 归档加入完整描述失败：%s", e.localizedDescription.UTF8String);
    MTLComputePipelineDescriptor *cd = [MTLComputePipelineDescriptor new];
    cd.computeFunction = [lib newFunctionWithName:@"cs_main"];
    BOOL addedc = [ar addComputePipelineFunctionsWithDescriptor:cd error:&e];
    CHECK(addedc, "A 归档加入计算管线失败：%s", e.localizedDescription.UTF8String);
    BOOL ser = [ar serializeToURL:[NSURL fileURLWithPath:path] error:&e];
    CHECK(ser, "A 归档序列化失败：%s", e.localizedDescription.UTF8String);
    long long sz = [[[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil][NSFileSize] longLongValue];
    printf("A1 设备归档落盘：期望 非空 → 真结果 %lld 字节\n", sz);
    CHECK(sz > 0, "A1 设备归档写出来是 %lld 字节", sz);

    // 重新打开（等价下次启动）
    MTLBinaryArchiveDescriptor *rd = [MTLBinaryArchiveDescriptor new];
    rd.url = [NSURL fileURLWithPath:path];
    id<MTLBinaryArchive> ar2 = [dev newBinaryArchiveWithDescriptor:rd error:&e];
    CHECK(ar2 != nil, "A 归档重新载入失败：%s", e.localizedDescription.UTF8String);
    if (!ar2) return;

    NSString *err = nil;
    id hit = try_render(dev, ar2, full_desc(lib, MTLPixelFormatBGRA8Unorm, MTLColorWriteMaskAll), &err);
    printf("A2 同描述命中：期望 是 → 真结果 %s\n", hit ? "是" : "否");
    CHECK(hit != nil, "A2 同描述 FailOnMiss 没命中：%s", err.UTF8String);

    err = nil;
    id miss = try_render(dev, ar2, full_desc(lib, MTLPixelFormatRGBA8Unorm, MTLColorWriteMaskAll), &err);
    printf("A3 反证 换颜色格式 BGRA8→RGBA8：期望 否 → 真结果 %s（%s）\n", miss ? "命中" : "否",
           miss ? "-" : head(err));
    CHECK(miss == nil, "A3 反证失败：换颜色格式仍命中");

    err = nil;
    id miss2 = try_render(dev, ar2, full_desc(lib, MTLPixelFormatBGRA8Unorm, MTLColorWriteMaskRed | MTLColorWriteMaskGreen), &err);
    printf("A4 反证 换写掩码（全开→红|绿）：期望 否 → 真结果 %s\n", miss2 ? "命中" : "否");
    CHECK(miss2 == nil, "A4 反证失败：换写掩码仍命中");

    err = nil;
    id chit = try_compute(dev, ar2, [lib newFunctionWithName:@"cs_main"], &err);
    printf("A5 计算管线同描述命中：期望 是 → 真结果 %s\n", chit ? "是" : "否");
    CHECK(chit != nil, "A5 计算管线没命中：%s", err.UTF8String);
}

// ---------- B 出包归档（metal-tt 编的 .bin，按 pso_gen 出的基础管线描述查）----------
static void pack_archive(id<MTLDevice> dev, NSString *archive, NSString *metallib, NSString *vs, NSString *fs) {
    NSError *e = nil;
    NSDictionary *at = [[NSFileManager defaultManager] attributesOfItemAtPath:archive error:nil];
    printf("B0 出包归档：%s（%lld 字节）\n", archive.lastPathComponent.UTF8String, [at[NSFileSize] longLongValue]);
    MTLBinaryArchiveDescriptor *ad = [MTLBinaryArchiveDescriptor new];
    ad.url = [NSURL fileURLWithPath:archive];
    id<MTLBinaryArchive> ar = [dev newBinaryArchiveWithDescriptor:ad error:&e];
    printf("B1 出包归档载入：期望 是 → 真结果 %s（%s）\n", ar ? "是" : "否", ar ? "-" : e.localizedDescription.UTF8String);
    CHECK(ar != nil, "B1 出包归档载入失败：%s", e.localizedDescription.UTF8String);
    id<MTLLibrary> lib = [dev newLibraryWithURL:[NSURL fileURLWithPath:metallib] error:&e];
    CHECK(lib != nil, "B 库载入失败：%s", e.localizedDescription.UTF8String);
    if (!ar || !lib) return;

    // pso_gen 的基础管线（颜色全留空）在脚本里写 pixel_format: Invalid，运行时描述必须逐字段相同
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [lib newFunctionWithName:vs];
    d.fragmentFunction = [lib newFunctionWithName:fs];
    for (int i = 0; i < 8; i++) d.colorAttachments[i].pixelFormat = MTLPixelFormatInvalid;
    NSString *err = nil;
    id hit = try_render(dev, ar, d, &err);
    printf("B2 基础管线描述（8 个附件 Invalid）命中：期望 是 → 真结果 %s\n", hit ? "是" : "否");
    CHECK(hit != nil, "B2 出包归档按基础描述没命中：%s", err.UTF8String);

    MTLRenderPipelineDescriptor *d2 = [MTLRenderPipelineDescriptor new];
    d2.vertexFunction = [lib newFunctionWithName:vs];
    d2.fragmentFunction = [lib newFunctionWithName:fs];
    for (int i = 0; i < 8; i++) d2.colorAttachments[i].pixelFormat = i ? MTLPixelFormatInvalid : MTLPixelFormatBGRA8Unorm;
    err = nil;
    id miss = try_render(dev, ar, d2, &err);
    printf("B3 反证 附件 0 换 BGRA8：期望 否 → 真结果 %s（%s）\n", miss ? "命中" : "否",
           miss ? "-" : head(err));
    CHECK(miss == nil, "B3 反证失败：换颜色格式仍命中");
}

int main(int argc, char **argv) {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) { printf("没有 Metal 设备\n"); return 3; }
        printf("设备：%s / 架构：%s / 系统：%s\n", dev.name.UTF8String, dev.architecture.name.UTF8String,
               NSProcessInfo.processInfo.operatingSystemVersionString.UTF8String);
        NSError *e = nil;
        NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"s2a_m3devarch_%d", getpid()]];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:@{} error:nil];
        // 库走离线编（fixture.h）：测的是归档命中，不是编译器
        id<MTLLibrary> lib = fx_lib(dev, @"t_m3devarch", @(k_src), &e);
        CHECK(lib != nil, "库编不出：%s", e.localizedDescription.UTF8String);
        if (lib) dev_archive(dev, lib, dir);
        if (argc >= 6 && !strcmp(argv[1], "--pack")) pack_archive(dev, @(argv[2]), @(argv[3]), @(argv[4]), @(argv[5]));
        else printf("B 未跑（没给 --pack <归档> <metallib> <顶点函数> <片元函数>；t_m3pack.sh 会带上）\n");
        [[NSFileManager defaultManager] removeItemAtPath:dir error:nil];
        printf("M3 归档单测：共 %d 项，失败 %d\n", g_checks, g_fail);
        return g_fail ? 1 : 0;
    }
}
