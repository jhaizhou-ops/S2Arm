// 动态 half 附件位图：改写后的片元主入口在真实 GPU 上画 MRT，并按原始像素位核对。
// 期望值是 IEEE binary16 向零舍入的独立常量；不调用被测量化函数计算期望。
#import "../gal_internal.h"
#include "../gal_formats.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures, checks;
#define CHECK(ok, ...) do { checks++; if (!(ok)) { failures++; fprintf(stderr, "FAIL " __VA_ARGS__); fputc('\n', stderr); } } while (0)
typedef struct { uint32_t input, rounded; uint16_t half; } sample;
static const sample samples[] = {
    {0x3ddf582du, 0x3ddf4000u, 0x2efau}, {0xbddf582du, 0xbddf4000u, 0xaefau},
    {0x33c00000u, 0x33800000u, 0x0001u}, {0xb3c00000u, 0xb3800000u, 0x8001u},
    {0x33000000u, 0x00000000u, 0x0000u}, {0xb3000000u, 0x80000000u, 0x8000u},
    {0x387fffffu, 0x387fc000u, 0x03ffu},
    {0x00000000u, 0x00000000u, 0x0000u}, {0x80000000u, 0x80000000u, 0x8000u},
    {0x47800000u, 0x477fe000u, 0x7bffu}, {0xc7800000u, 0xc77fe000u, 0xfbffu},
    {0x7f7fffffu, 0x477fe000u, 0x7bffu}, {0xff7fffffu, 0xc77fe000u, 0xfbffu},
    {0x7f800000u, 0x7f800000u, 0x7c00u}, {0xff800000u, 0xff800000u, 0xfc00u},
    {0x7fc12345u, 0x7fc12345u, 0x7e00u}, {0xffc12345u, 0xffc12345u, 0xfe00u},
};
enum { NSAMPLES = sizeof samples / sizeof samples[0] };
GAL_MTL4_ZONE_BEGIN
static const char vertex_source[] =
"#include <metal_stdlib>\nusing namespace metal;\n"
"struct cv_out\n{\n    float4 position [[position]];\n};\n"
"vertex cv_out cv(uint id [[vertex_id]])\n{\n"
"    float2 p = float2(float((id << 1) & 2u), float(id & 2u));\n"
"    cv_out out = {};\n    out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);\n    return out;\n}\n";
static const char fragment_source[] =
"#include <metal_stdlib>\nusing namespace metal;\n"
"struct cf_out\n{\n    float4 first [[color(0)]];\n    float4 second [[color(1)]];\n    uint4 integer [[color(2)]];\n};\n"
"fragment cf_out cf(constant uint* inputs [[buffer(0)]], float4 position [[position]])\n{\n"
"    uint bits = inputs[uint(position.x)];\n    cf_out out = {};\n"
"    out.first = as_type<float4>(uint4(bits));\n    out.second = as_type<float4>(uint4(bits));\n    out.integer = uint4(bits);\n    return out;\n}\n";
static const char dual_source[] =
"#include <metal_stdlib>\nusing namespace metal;\n"
"struct cd_out\n{\n    float4 first [[color(0), index(0)]];\n    float4 second [[color(0), index(1)]];\n};\n"
"fragment cd_out cd(constant uint* inputs [[buffer(0)]])\n{\n    cd_out out = {};\n"
"    out.first = as_type<float4>(uint4(inputs[0]));\n    out.second = as_type<float4>(uint4(inputs[1]));\n    return out;\n}\n";

static id<MTLLibrary> library(id<MTLDevice> device, const char *source, const char *label) {
    NSError *error = nil;
    id<MTLLibrary> result = [device newLibraryWithSource:@(source) options:[MTLCompileOptions new] error:&error];
    CHECK(result != nil, "%s library: %s", label, error.localizedDescription.UTF8String); return result;
}
static id function(id<MTLLibrary> library, NSString *name) { return gal_be_fn_desc(library, name); }

static void draw(id<MTLDevice> device, id<MTL4Compiler> compiler, id<MTLLibrary> vertex, id<MTLLibrary> fragment,
                 uint32_t mask, BOOL half0, BOOL half1) {
    const char *path = "full";
    NSError *error = nil;
    MTL4RenderPipelineDescriptor *pd = [MTL4RenderPipelineDescriptor new];
    pd.vertexFunctionDescriptor = function(vertex, @"cv"); pd.fragmentFunctionDescriptor = function(fragment, @"cf");
    MTLPixelFormat formats[] = {half0 ? MTLPixelFormatRGBA16Float : MTLPixelFormatRGBA32Float,
        half1 ? MTLPixelFormatRGBA16Float : MTLPixelFormatRGBA32Float, MTLPixelFormatRGBA32Uint};
    for (int slot = 0; slot < 3; slot++) pd.colorAttachments[slot].pixelFormat = formats[slot];
    id<MTLRenderPipelineState> pipeline = [compiler newRenderPipelineStateWithDescriptor:pd compilerTaskOptions:nil error:&error];
    CHECK(pipeline != nil, "%s pipeline: %s", path, error.localizedDescription.UTF8String); if (!pipeline) return;
    id<MTLTexture> textures[3]; MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    for (int slot = 0; slot < 3; slot++) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:formats[slot] width:NSAMPLES height:1 mipmapped:NO];
        td.storageMode = MTLStorageModeShared; td.usage = MTLTextureUsageRenderTarget;
        textures[slot] = [device newTextureWithDescriptor:td];
        CHECK(textures[slot] != nil, "%s texture slot %d", path, slot); if (!textures[slot]) return;
        pass.colorAttachments[slot].texture = textures[slot]; pass.colorAttachments[slot].loadAction = MTLLoadActionClear; pass.colorAttachments[slot].storeAction = MTLStoreActionStore;
    }
    uint32_t inputs[NSAMPLES]; for (int i = 0; i < NSAMPLES; i++) inputs[i] = samples[i].input;
    id<MTLBuffer> input = [device newBufferWithBytes:inputs length:sizeof inputs options:MTLResourceStorageModeShared];
    id<MTLBuffer> control = [device newBufferWithBytes:&mask length:sizeof mask options:MTLResourceStorageModeShared];
    CHECK(input && control, "%s actual input buffers", path); if (!input || !control) return;
    id<MTLCommandQueue> queue = [device newCommandQueue]; id<MTLCommandBuffer> command = [queue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:pass];
    [encoder setRenderPipelineState:pipeline]; [encoder setFragmentBuffer:input offset:0 atIndex:0]; [encoder setFragmentBuffer:control offset:0 atIndex:GAL_COLOR_ROUND_SLOT];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
    CHECK(command.status == MTLCommandBufferStatusCompleted, "%s real draw: %s", path, command.error.localizedDescription.UTF8String);
    if (command.status != MTLCommandBufferStatusCompleted) return;
    for (int slot = 0; slot < 3; slot++) {
        BOOL half = formats[slot] == MTLPixelFormatRGBA16Float; uint8_t pixels[NSAMPLES * 16];
        [textures[slot] getBytes:pixels bytesPerRow:NSAMPLES * (half ? 8 : 16) fromRegion:MTLRegionMake2D(0, 0, NSAMPLES, 1) mipmapLevel:0];
        for (int i = 0; i < NSAMPLES; i++) for (int channel = 0; channel < 4; channel++) {
            if (half) {
                uint16_t bits; memcpy(&bits, pixels + (i * 4 + channel) * 2, 2);
                BOOL nan = (samples[i].input & 0x7fffffffu) > 0x7f800000u;
                BOOL ok = nan ? (bits & 0x7c00u) == 0x7c00u && (bits & 0x03ffu) != 0 : bits == samples[i].half;
                CHECK(ok, "%s mask=%u slot=%d input=%08x half=%04x expected=%04x", path, mask, slot, samples[i].input, bits, samples[i].half);
            } else {
                uint32_t bits; memcpy(&bits, pixels + (i * 4 + channel) * 4, 4);
                uint32_t expected = slot < 2 && (mask >> slot & 1) ? samples[i].rounded : samples[i].input;
                CHECK(bits == expected, "%s mask=%u slot=%d input=%08x float/int=%08x expected=%08x", path, mask, slot, samples[i].input, bits, expected);
            }
        }
    }
    printf("%s mask=%u formats=%s/%s/uint: actual pixels checked\n", path, mask, half0 ? "half" : "float", half1 ? "half" : "float");
}
static void dual_source_draws(id<MTLDevice> device, id<MTL4Compiler> compiler, id<MTLLibrary> vertex) {
    char why[256] = ""; char *rounded = gal_color_round_msl(dual_source, "cd", why);
    CHECK(rounded != NULL, "legal dual-source export rewrite: %s", why); if (!rounded) return;
    id<MTLLibrary> fragment = library(device, rounded, "dual-source"); free(rounded); if (!fragment) return;
    for (int test = 0; test < 3; test++) {
        BOOL blend = test == 2; uint32_t mask = test == 1 ? 1 : 0;
        // 最后一例 0.5 * source1，无舍入误差；可直接按 FP32 位验证 source1 混合因子未损失精度。
        uint32_t inputs[] = {blend ? 0x3f000000u : 0x3ddf582du, blend ? 0x3ddf582du : 0x3eaaaaabu};
        uint32_t expected = blend ? 0x3d5f582du : mask ? 0x3ddf4000u : 0x3ddf582du;
        NSError *error = nil; MTL4RenderPipelineDescriptor *pd = [MTL4RenderPipelineDescriptor new];
        pd.vertexFunctionDescriptor = function(vertex, @"cv"); pd.fragmentFunctionDescriptor = function(fragment, @"cd");
        MTL4RenderPipelineColorAttachmentDescriptor *color = pd.colorAttachments[0]; color.pixelFormat = MTLPixelFormatRGBA32Float;
        if (blend) {
            color.blendingState = MTL4BlendStateEnabled; color.rgbBlendOperation = color.alphaBlendOperation = MTLBlendOperationAdd;
            color.sourceRGBBlendFactor = MTLBlendFactorSource1Color; color.sourceAlphaBlendFactor = MTLBlendFactorSource1Alpha;
            color.destinationRGBBlendFactor = color.destinationAlphaBlendFactor = MTLBlendFactorZero;
        }
        id<MTLRenderPipelineState> pipeline = [compiler newRenderPipelineStateWithDescriptor:pd compilerTaskOptions:nil error:&error];
        CHECK(pipeline != nil, "dual-source pipeline mask=%u blend=%d: %s", mask, blend, error.localizedDescription.UTF8String); if (!pipeline) continue;
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:1 height:1 mipmapped:NO];
        td.storageMode = MTLStorageModeShared; td.usage = MTLTextureUsageRenderTarget; id<MTLTexture> texture = [device newTextureWithDescriptor:td];
        id<MTLBuffer> input = [device newBufferWithBytes:inputs length:sizeof inputs options:MTLResourceStorageModeShared];
        id<MTLBuffer> control = [device newBufferWithBytes:&mask length:sizeof mask options:MTLResourceStorageModeShared];
        CHECK(texture && input && control, "dual-source real resources"); if (!texture || !input || !control) continue;
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor]; pass.colorAttachments[0].texture = texture;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear; pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLCommandQueue> queue = [device newCommandQueue]; id<MTLCommandBuffer> command = [queue commandBuffer];
        id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:pass];
        [encoder setRenderPipelineState:pipeline]; [encoder setFragmentBuffer:input offset:0 atIndex:0]; [encoder setFragmentBuffer:control offset:0 atIndex:GAL_COLOR_ROUND_SLOT];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
        CHECK(command.status == MTLCommandBufferStatusCompleted, "dual-source real draw: %s", command.error.localizedDescription.UTF8String);
        if (command.status != MTLCommandBufferStatusCompleted) continue;
        uint32_t pixels[4]; [texture getBytes:pixels bytesPerRow:sizeof pixels fromRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0];
        for (int channel = 0; channel < 4; channel++) CHECK(pixels[channel] == expected, "dual-source mask=%u blend=%d channel=%d actual=%08x expected=%08x", mask, blend, channel, pixels[channel], expected);
        printf("dual-source mask=%u Source1Color-blend=%d: actual pixel=%08x\n", mask, blend, pixels[0]);
    }
}

// 不直接设置 Metal 参数槽：程序、目标、状态和绘制全部经过真实 GAL。
// 单独的整数附件读出实际绑定的位图，避免 Mac 原生 half RTZ 掩盖错绑 / 漏绑。
static void gal_mask_draws(id<MTLDevice> device, id<MTLLibrary> vertex) {
    enum { WIDTH = 10 };
    int init = nxgal_init(0);
    CHECK(init == 0, "GAL mask integration init=%d", init); if (init) return;
    static gal_prog programs[3]; uint32_t handles[3];
    for (int program = 0; program < 3; program++) {
        int integer = program == 1;
        NSString *source = [NSString stringWithFormat:
            @"#include <metal_stdlib>\nusing namespace metal;\n"
             "struct MaskOut { float4 a [[color(0)]]; float4 b [[color(1)]]; %@4 c [[color(2)]]; uint witness [[color(3)]]; };\n"
             "fragment MaskOut mask_fs(constant uint &mask [[buffer(%d)]]) {\n"
             "  MaskOut o; o.a = o.b = float4(0.5, 0.5, 0.5, 1.0);\n"
             "  o.c = %@; o.witness = mask; return o; }\n",
             integer ? @"uint" : @"float", GAL_COLOR_ROUND_SLOT,
             integer ? @"uint4(123u)" : @"float4(0.5, 0.5, 0.5, 1.0)"];
        id<MTLLibrary> fragment = library(device, source.UTF8String, integer ? "GAL integer witness" : "GAL float witness");
        if (!fragment) { nxgal_shutdown(); return; }
        gal_prog *p = &programs[program];
        p->fn[1] = function(vertex, @"cv"); p->fn[5] = function(fragment, @"mask_fs");
        p->fs_outputs = 15; p->fs_output_ctype[3] = 1; p->fs_output_ctype[2] = integer;
        p->fs_color_round = program != 2;
        p->hash = 0xc010a000u + program;
        for (int stage = 0; stage < 6; stage++) p->size_buf_index[stage] = -1;
        handles[program] = gal_prog_register_builtin(p);
        CHECK(handles[program] != 0, "register real GAL witness program %d", program);
        if (!handles[program]) { nxgal_shutdown(); return; }
    }
    nxgal_depth_test depth = {0, 0, 8}; nxgal_set_depth_test(&depth);
    nxgal_stencil stencil = {0}; nxgal_set_stencil_test(&stencil);
    nxgal_set_face_culling(0, 0x405); nxgal_set_front_face(0x901); nxgal_set_topology(4);
    nxgal_viewport viewport = {0, 0, WIDTH, 1, {0, 2, 4, 6}, 0, 1}; nxgal_set_viewports(&viewport, 1);
    uint32_t write_masks[8] = {15, 15, 15, 15, 15, 15, 15, 15}; nxgal_set_color_masks(write_masks, 8);
    const struct { const char *name; int formats[3], bytes[3]; uint32_t mask; int integer, unrounded; } configurations[] = {
        {"R16F/RG16F/RGBA16F", {F_R16Float, F_R16G16Float, F_R16G16B16A16Float}, {2, 4, 8}, 7, 0, 0},
        {"R32F/RG32F/RGBA32F", {F_R32Float, F_R32G32Float, F_R32G32B32A32Float}, {4, 8, 16}, 0, 0, 0},
        {"R16F/RG32F/RGBA16F", {F_R16Float, F_R32G32Float, F_R16G16B16A16Float}, {2, 8, 8}, 5, 0, 0},
        {"R32F/RG16F/RGBA32F", {F_R32Float, F_R16G16Float, F_R32G32B32A32Float}, {4, 4, 16}, 2, 0, 0},
        {"R16F/RG16F/R16Uint", {F_R16Float, F_R16G16Float, F_R16Uint}, {2, 4, 2}, 3, 1, 0},
        {"unrewritten R16F/RG16F/RGBA16F", {F_R16Float, F_R16G16Float, F_R16G16B16A16Float}, {2, 4, 8}, 0, 0, 1},
        // 重访同一个程序 / 格式键，验证 PSO 缓存命中恢复其位图。
        {"cached R16F/RG16F/RGBA16F", {F_R16Float, F_R16G16Float, F_R16G16B16A16Float}, {2, 4, 8}, 7, 0, 0},
    };
    for (unsigned config = 0; config < sizeof configurations / sizeof *configurations; config++) {
        uint32_t targets[4] = {0}; const __typeof__(configurations[0]) *c = &configurations[config];
        for (int slot = 0; slot < 4; slot++) {
            nxgal_tex_info ti = {WIDTH, 1, 1, 1, 1, 1, 1, slot == 3 ? 4 : c->bytes[slot],
                slot == 3 ? F_R32Uint : c->formats[slot], 0, 1, {2, 3, 4, 5}};
            targets[slot] = nxgal_tex_create(&ti);
            CHECK(targets[slot] != 0, "GAL %s create attachment %d", c->name, slot);
        }
        if (!targets[0] || !targets[1] || !targets[2] || !targets[3]) {
            for (int slot = 0; slot < 4; slot++) if (targets[slot]) nxgal_tex_release(targets[slot]);
            continue;
        }
        nxgal_set_program(handles[c->unrounded ? 2 : c->integer]); nxgal_set_render_targets(targets, 4, 0);
        uint32_t expected[WIDTH] = {c->mask, c->mask & ~1u, c->mask & ~3u, 0,
            c->mask, c->mask, 0, c->mask, c->mask, c->mask & ~1u};
        for (int x = 0; x < WIDTH; x++) {
            // 5：同 encoder 重复绘制；8：结束命令后不改 PSO 状态，新 encoder 重绑。
            if (x == 8) gal_finish();
            if (x != 5 && x != 8) {
                nxgal_set_multisample(x == 6, 0, 0);
                for (int slot = 0; slot < 4; slot++) {
                    nxgal_blend blend = {0, {0, 0, 0, 0}, 1, 2, 1, 1, 2, 1};
                    blend.enable = (x == 1 || x == 9) ? slot == 0 : x == 2 ? slot < 2 : x == 3 ? slot < 3 && !(c->integer && slot == 2) : 0;
                    nxgal_set_blend(slot, &blend);
                }
            }
            nxgal_rect scissor = {x, 0, 1, 1}; nxgal_set_scissors(&scissor, 1);
            nxgal_set_viewports(&viewport, 1);
            nxgal_draw(3, 1, 0, 0);
        }
        uint32_t witness[WIDTH]; memset(witness, 0xee, sizeof witness);
        int count = nxgal_tex_get_data(targets[3], 0, 0, witness, sizeof witness);
        CHECK(count == sizeof witness, "GAL %s witness readback bytes=%d", c->name, count);
        for (int x = 0; x < WIDTH; x++) CHECK(witness[x] == expected[x],
            "GAL %s draw=%d bound mask=%u expected=%u", c->name, x, witness[x], expected[x]);
        for (int slot = 0; slot < 3; slot++) {
            uint8_t pixels[WIDTH * 16]; memset(pixels, 0xee, sizeof pixels);
            int bytes = WIDTH * c->bytes[slot];
            CHECK(nxgal_tex_get_data(targets[slot], 0, 0, pixels, bytes) == (uint64_t)bytes,
                "GAL %s attachment %d actual color readback", c->name, slot);
            int integer = c->integer && slot == 2;
            int half = !integer && (c->formats[slot] == F_R16Float || c->formats[slot] == F_R16G16Float || c->formats[slot] == F_R16G16B16A16Float);
            int width = half || integer ? 2 : 4;
            for (int x = 0; x < WIDTH; x++) for (int channel = 0; channel < c->bytes[slot] / width; channel++) {
                uint32_t bits = 0; memcpy(&bits, pixels + x * c->bytes[slot] + channel * width, width);
                uint32_t value = integer ? 123 : half ? (channel == 3 ? 0x3c00 : 0x3800) : (channel == 3 ? 0x3f800000 : 0x3f000000);
                CHECK(bits == value, "GAL %s slot=%d pixel=%d channel=%d actual=%08x expected=%08x", c->name, slot, x, channel, bits, value);
            }
        }
        for (int slot = 0; slot < 4; slot++) nxgal_tex_release(targets[slot]);
        printf("GAL %s: actual mask/color pixels checked (blend, a2c, repeated/cached PSO, new encoder)\n", c->name);
    }
    nxgal_shutdown();
}
static int t_main(void) {
    @autoreleasepool {
        char why[256] = "";
        // 产品顺序（gal_prog.m xc_shader1）：最终 MSL = 原 MSL 改写颜色出口
        char *rounded = gal_color_round_msl(fragment_source, "cf", why);
        CHECK(rounded != NULL, "generate full export: %s", why); if (!rounded) return 1;
        id<MTLDevice> device = MTLCreateSystemDefaultDevice(); CHECK(device != nil, "actual Metal device"); if (!device) return 1;
        printf("device=%s os=%s\n", device.name.UTF8String, NSProcessInfo.processInfo.operatingSystemVersionString.UTF8String);
        NSError *error = nil; id<MTL4Compiler> compiler = [device newCompilerWithDescriptor:[MTL4CompilerDescriptor new] error:&error];
        CHECK(compiler != nil, "real Metal 4 compiler: %s", error.localizedDescription.UTF8String); if (!compiler) return 1;
        id<MTLLibrary> vertex = library(device, vertex_source, "vertex"), fragment = library(device, rounded, "full");
        free(rounded); if (!vertex || !fragment) return 1;
        for (NSNumber *mask in @[@0, @1, @2, @7]) draw(device, compiler, vertex, fragment, mask.unsignedIntValue, NO, NO);
        draw(device, compiler, vertex, fragment, 1, YES, NO);
        draw(device, compiler, vertex, fragment, 2, NO, YES);
        dual_source_draws(device, compiler, vertex);
        gal_mask_draws(device, vertex);
        printf("%s %d/%d checks\n", failures ? "FAIL" : "PASS", checks - failures, checks);
    }
    return failures ? 1 : 0;
}
GAL_MTL4_ZONE_END

int main(void) { @autoreleasepool {
    if (@available(macOS 26.0, *)) return t_main();
    printf("跳过：要 macOS 26（Metal 4）\n"); return 0;
} }
