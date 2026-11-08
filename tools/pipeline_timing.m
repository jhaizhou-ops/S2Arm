// 逐项计时 Metal 管线创建；输入是 metallib 与明确给出的顶点/片元配对及状态。
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <mach/mach_time.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

static double elapsed_ms(uint64_t start) {
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    return (mach_absolute_time() - start) * (double)tb.numer / tb.denom / 1e6;
}
static BOOL string_value(id value) { return [value isKindOfClass:NSString.class] && [value length] > 0; }
static BOOL keys_only(NSDictionary *row, NSArray<NSString *> *keys) {
    NSSet *allowed = [NSSet setWithArray:keys];
    for (id key in row) if (![allowed containsObject:key]) return NO;
    return YES;
}
static NSNumber *format(NSString *name) {
    NSDictionary *formats = @{@"rgba8unorm": @(MTLPixelFormatRGBA8Unorm), @"bgra8unorm": @(MTLPixelFormatBGRA8Unorm),
                              @"rgba16float": @(MTLPixelFormatRGBA16Float), @"r8unorm": @(MTLPixelFormatR8Unorm)};
    return formats[name];
}
static NSNumber *vertex_format(NSString *name) {
    NSDictionary *formats = @{@"float": @(MTLVertexFormatFloat), @"float2": @(MTLVertexFormatFloat2),
                              @"float3": @(MTLVertexFormatFloat3), @"float4": @(MTLVertexFormatFloat4),
                              @"int4": @(MTLVertexFormatInt4), @"uint4": @(MTLVertexFormatUInt4),
                              @"uchar4normalized": @(MTLVertexFormatUChar4Normalized)};
    return formats[name];
}
static BOOL uint_value(id value, NSUInteger max, NSUInteger *out) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return NO;
    double d = [value doubleValue];
    if (!isfinite(d) || d < 0 || d > max || floor(d) != d) return NO;
    *out = (NSUInteger)d; return YES;
}
static MTLVertexDescriptor *vertex_descriptor(NSDictionary *row, NSString **error) {
    id attrs = row[@"attributes"], buffers = row[@"buffers"];
    if (![attrs isKindOfClass:NSArray.class] || ![buffers isKindOfClass:NSArray.class]) {
        *error = @"attributes 和 buffers 必须为数组"; return nil;
    }
    MTLVertexDescriptor *desc = [MTLVertexDescriptor vertexDescriptor];
    NSMutableSet *seenBuffers = [NSMutableSet set], *seenAttrs = [NSMutableSet set];
    for (id item in buffers) {
        if (![item isKindOfClass:NSDictionary.class] || !keys_only(item, @[@"index", @"stride"])) { *error = @"buffers 项或字段无效"; return nil; }
        NSUInteger index, stride;
        if (!uint_value(item[@"index"], 30, &index) || !uint_value(item[@"stride"], 2048, &stride) || !stride || [seenBuffers containsObject:@(index)]) {
            *error = @"buffer index/stride 无效或重复"; return nil;
        }
        [seenBuffers addObject:@(index)]; desc.layouts[index].stride = stride;
        desc.layouts[index].stepFunction = MTLVertexStepFunctionPerVertex; desc.layouts[index].stepRate = 1;
    }
    for (id item in attrs) {
        if (![item isKindOfClass:NSDictionary.class] || !keys_only(item, @[@"index", @"buffer", @"offset", @"format"])) { *error = @"attributes 项或字段无效"; return nil; }
        NSUInteger index, buffer, offset;
        if (!uint_value(item[@"index"], 30, &index) || !uint_value(item[@"buffer"], 30, &buffer) || !uint_value(item[@"offset"], 2048, &offset) ||
            !string_value(item[@"format"]) || !vertex_format(item[@"format"]) || [seenAttrs containsObject:@(index)] || ![seenBuffers containsObject:@(buffer)]) {
            *error = @"attribute 字段无效、重复或缺少 buffer"; return nil;
        }
        [seenAttrs addObject:@(index)]; desc.attributes[index].format = vertex_format(item[@"format"]).unsignedIntegerValue;
        desc.attributes[index].bufferIndex = buffer; desc.attributes[index].offset = offset;
    }
    return desc;
}
static NSDictionary *measure(id<MTLDevice> device, id<MTLLibrary> lib, id compiler, BOOL metal4, id row, NSUInteger line) {
    if (![row isKindOfClass:NSDictionary.class]) return @{@"index": @(line), @"status": @"error", @"error": @"记录必须为对象"};
    id name = row[@"name"], vs = row[@"vertex"], fs = row[@"fragment"], color = row[@"color"], blend = row[@"blend"], topology = row[@"topology"];
    NSUInteger samples;
    NSMutableDictionary *out = [@{@"index": @(line), @"name": string_value(name) ? name : @"", @"status": @"error"} mutableCopy];
    if (!keys_only(row, @[@"name", @"vertex", @"fragment", @"color", @"blend", @"topology", @"samples", @"attributes", @"buffers"]) ||
        !string_value(name) || !string_value(vs) || !string_value(fs) || !string_value(color) || !format(color) ||
        !string_value(blend) || ![@[@"none", @"alpha"] containsObject:blend] || !string_value(topology) ||
        ![@[@"triangle", @"line", @"point", @"unspecified"] containsObject:topology] ||
        !uint_value(row[@"samples"], 8, &samples) || !samples || ![device supportsTextureSampleCount:samples]) {
        out[@"error"] = @"名称、函数名或渲染状态无效"; return out;
    }
    NSString *err = nil;
    MTLVertexDescriptor *vertexDesc = vertex_descriptor(row, &err);
    if (!vertexDesc) { out[@"error"] = err; return out; }
    id<MTLFunction> vertex = [lib newFunctionWithName:vs], fragment = [lib newFunctionWithName:fs];
    if (!vertex || vertex.functionType != MTLFunctionTypeVertex || !fragment || fragment.functionType != MTLFunctionTypeFragment) {
        out[@"error"] = @"函数不存在或阶段不匹配"; return out;
    }
    MTLPrimitiveTopologyClass topo = [topology isEqual:@"triangle"] ? MTLPrimitiveTopologyClassTriangle :
        [topology isEqual:@"line"] ? MTLPrimitiveTopologyClassLine : [topology isEqual:@"point"] ? MTLPrimitiveTopologyClassPoint : MTLPrimitiveTopologyClassUnspecified;
    NSError *error = nil; id<MTLRenderPipelineState> state = nil; double ms = 0;
    if (metal4) {
        if (@available(macOS 26.0, *)) {
            MTL4LibraryFunctionDescriptor *v = [MTL4LibraryFunctionDescriptor new]; v.library = lib; v.name = vs;
            MTL4LibraryFunctionDescriptor *f = [MTL4LibraryFunctionDescriptor new]; f.library = lib; f.name = fs;
            MTL4RenderPipelineDescriptor *d = [MTL4RenderPipelineDescriptor new];
            d.vertexFunctionDescriptor = v; d.fragmentFunctionDescriptor = f; d.vertexDescriptor = vertexDesc;
            d.rasterSampleCount = samples; d.inputPrimitiveTopology = topo;
            MTL4RenderPipelineColorAttachmentDescriptor *c = d.colorAttachments[0]; c.pixelFormat = format(color).unsignedIntegerValue;
            if ([blend isEqual:@"alpha"]) { c.blendingState = MTL4BlendStateEnabled; c.sourceRGBBlendFactor = c.sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha; c.destinationRGBBlendFactor = c.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha; }
            uint64_t start = mach_absolute_time();
            state = [(id<MTL4Compiler>)compiler newRenderPipelineStateWithDescriptor:d compilerTaskOptions:nil error:&error];
            ms = elapsed_ms(start);
        }
    } else {
        MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new]; d.vertexFunction = vertex; d.fragmentFunction = fragment;
        d.vertexDescriptor = vertexDesc; d.rasterSampleCount = samples; d.inputPrimitiveTopology = topo;
        MTLRenderPipelineColorAttachmentDescriptor *c = d.colorAttachments[0]; c.pixelFormat = format(color).unsignedIntegerValue;
        if ([blend isEqual:@"alpha"]) { c.blendingEnabled = YES; c.sourceRGBBlendFactor = c.sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha; c.destinationRGBBlendFactor = c.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha; }
        uint64_t start = mach_absolute_time(); state = [device newRenderPipelineStateWithDescriptor:d error:&error]; ms = elapsed_ms(start);
    }
    out[@"milliseconds"] = @(ms);
    if (!state) { out[@"error"] = error.localizedDescription ?: @"管线创建失败"; return out; }
    out[@"status"] = @"ok"; return out;
}
static NSDictionary *coverage(id<MTLLibrary> lib, NSArray *cases, NSArray *results) {
    NSMutableSet *vertexOK = [NSMutableSet set], *fragmentOK = [NSMutableSet set];
    NSMutableSet *vertexFailed = [NSMutableSet set], *fragmentFailed = [NSMutableSet set];
    NSMutableArray *failedPairs = [NSMutableArray array];
    for (NSUInteger i = 0; i < cases.count; i++) {
        id row = cases[i];
        if (![row isKindOfClass:NSDictionary.class]) { [failedPairs addObject:@{@"index": @(i)}]; continue; }
        id vertex = row[@"vertex"], fragment = row[@"fragment"];
        BOOL ok = [results[i][@"status"] isEqual:@"ok"];
        if (string_value(vertex)) [(ok ? vertexOK : vertexFailed) addObject:vertex];
        if (string_value(fragment)) [(ok ? fragmentOK : fragmentFailed) addObject:fragment];
        if (!ok) [failedPairs addObject:@{@"index": @(i), @"vertex": string_value(vertex) ? vertex : @"", @"fragment": string_value(fragment) ? fragment : @""}];
    }
    NSMutableArray *vertices = [NSMutableArray array], *fragments = [NSMutableArray array];
    NSMutableArray *other = [NSMutableArray array], *unknown = [NSMutableArray array];
    for (NSString *name in [lib.functionNames sortedArrayUsingSelector:@selector(compare:)]) {
        id<MTLFunction> function = [lib newFunctionWithName:name];
        if (!function) { [unknown addObject:name]; continue; }
        NSMutableArray *destination = function.functionType == MTLFunctionTypeVertex ? vertices :
            function.functionType == MTLFunctionTypeFragment ? fragments : nil;
        if (destination) {
            NSSet *ok = function.functionType == MTLFunctionTypeVertex ? vertexOK : fragmentOK;
            NSSet *failed = function.functionType == MTLFunctionTypeVertex ? vertexFailed : fragmentFailed;
            [destination addObject:@{@"name": name, @"status": [ok containsObject:name] ? @"covered" : [failed containsObject:name] ? @"failed_only" : @"uncovered"}];
        } else {
            [other addObject:@{@"name": name, @"function_type": @(function.functionType)}];
        }
    }
    return @{@"vertex": vertices, @"fragment": fragments, @"other_stages": other,
             @"uninspectable": unknown, @"failed_pairs": failedPairs};
}
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 4 || (strcmp(argv[1], "metal3") && strcmp(argv[1], "metal4"))) {
            fprintf(stderr, "用法：pipeline_timing metal3|metal4 <metallib> <cases.json>\n"); return 2;
        }
        BOOL metal4 = !strcmp(argv[1], "metal4"); NSError *error = nil;
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) { fprintf(stderr, "没有 Metal 设备\n"); return 2; }
        id<MTLLibrary> lib = [device newLibraryWithURL:[NSURL fileURLWithPath:@(argv[2])] error:&error];
        if (!lib) { fprintf(stderr, "加载 metallib 失败：%s\n", error.localizedDescription.UTF8String ?: "unknown"); return 2; }
        NSData *data = [NSData dataWithContentsOfFile:@(argv[3]) options:0 error:&error];
        id cases = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&error] : nil;
        if (![cases isKindOfClass:NSArray.class] || ![cases count]) { fprintf(stderr, "cases 必须是非空 JSON 数组\n"); return 2; }
        id compiler = nil;
        if (metal4) {
            if (@available(macOS 26.0, *)) compiler = [device newCompilerWithDescriptor:[MTL4CompilerDescriptor new] error:&error];
            if (!compiler) { fprintf(stderr, "Metal 4 编译器不可用：%s\n", error.localizedDescription.UTF8String ?: "当前系统或设备不支持"); return 2; }
        }
        NSMutableArray *results = [NSMutableArray array], *over1 = [NSMutableArray array], *over5 = [NSMutableArray array];
        NSUInteger failures = 0;
        for (NSUInteger i = 0; i < [cases count]; i++) {
            @autoreleasepool {
                NSDictionary *result = measure(device, lib, compiler, metal4, cases[i], i);
                [results addObject:result];
                if (![result[@"status"] isEqual:@"ok"]) failures++;
                if ([result[@"milliseconds"] doubleValue] > 1000) [over1 addObject:@(i)];
                if ([result[@"milliseconds"] doubleValue] > 5000) [over5 addObject:@(i)];
            }
        }
        // 覆盖检查放在计时之后，避免枚举未测函数影响本次计时。
        NSDictionary *report = @{@"backend": metal4 ? @"metal4" : @"metal3", @"device": device.name ?: @"unknown",
            @"os": NSProcessInfo.processInfo.operatingSystemVersionString, @"cache": @"未控制系统/驱动缓存",
            @"results": results, @"over_1s": over1, @"over_5s": over5, @"failures": @(failures),
            @"coverage": coverage(lib, cases, results)};
        NSData *json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:&error];
        if (!json) { fprintf(stderr, "输出 JSON 失败\n"); return 2; }
        fwrite(json.bytes, 1, json.length, stdout); fputc('\n', stdout);
        return failures ? 1 : 0;
    }
}
