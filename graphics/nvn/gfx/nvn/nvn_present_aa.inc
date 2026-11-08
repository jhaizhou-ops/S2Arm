// Direct scan-out postprocessing. Reuse GAL's licensed SMAA source and LUTs (no FXAA: NVIDIA FXAA 3.11 carries no license grant, jhz 10-30),
// but encode on the direct present command buffer, after its producer wait.
#include "nvn_aa_edge.h"
#include "nvn_aa_blend.h"
#include "nvn_aa_neighbour.h"
#include "nvn_aa_lut.h"

static int g_present_aa, g_present_nearest, g_present_fx;   // g_present_fx：S2A_SCALING_FILTER=MetalFX（nvn_present_fx.inc）
static void present_options(void) {
    static int initialized;
    if (initialized) return;
    const char *aa = getenv("S2A_ANTI_ALIASING"), *filter = getenv("S2A_SCALING_FILTER");
    if (!aa || !strcmp(aa, "None")) g_present_aa = 0;
    else if (!strcmp(aa, "SmaaMedium")) g_present_aa = 3;
    else if (!strcmp(aa, "SmaaHigh")) g_present_aa = 4;
    else MDIE("【红】 invalid S2A_ANTI_ALIASING=%s", aa);
    if (!filter || !strcmp(filter, "Bilinear")) g_present_nearest = 0;
    else if (!strcmp(filter, "Nearest")) g_present_nearest = 1;
    else if (!strcmp(filter, "MetalFX")) g_present_fx = 1;   // 放大时 MetalFX 空间放大；不是放大的帧仍按双线性
    else MDIE("【红】 invalid S2A_SCALING_FILTER=%s", filter);
    initialized = 1;
    MLOG("直连画面设置：抗锯齿 %s，缩放滤镜 %s", aa ?: "None", filter ?: "Bilinear");
}

@interface NvPresentAA : NSObject {
@public
    id<MTLTexture> input, output, edge, blend, linear;
    id<MTLBuffer> size, cropUV;
    id cropTable, tables[3];
    id<MTLComputePipelineState> pipelines[3];
    NSArray<id<MTLResource>> *resources;
    BOOL busy; // guarded by g_pq_mu; only actual GPU feedback clears it
}
@end
@implementation NvPresentAA @end
// Three asynchronous present slots plus a separate synchronous screenshot slot.
static NvPresentAA *g_present_aa_slots[4];
static id<MTLLibrary> g_present_aa_libs[3];
static id<MTLTexture> g_present_area, g_present_search;
static id<MTLSamplerState> g_present_aa_sampler;

static id<MTLTexture> present_aa_texture(MTLPixelFormat format, NSUInteger w, NSUInteger h, MTLTextureUsage usage) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:w height:h mipmapped:NO];
    d.storageMode = MTLStorageModePrivate;
    d.usage = usage;
    return [g_dev newTextureWithDescriptor:d];
}
static id<MTLTexture> present_aa_lut(MTLPixelFormat format, NSUInteger w, NSUInteger h, const void *bytes, NSUInteger row) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:w height:h mipmapped:NO];
    d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> t = [g_dev newTextureWithDescriptor:d];
    if (t) { [t replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:bytes bytesPerRow:row]; res_add(t); }
    return t;
}
static id<MTLComputePipelineState> present_aa_pipeline(int index, NSUInteger w, NSUInteger h) {
    const char *sources[] = {k_aa_edge, k_aa_blend, k_aa_neighbour};
    NSString *names[] = {@"aa_edge", @"aa_blend", @"aa_neighbour"};
    NSError *error = nil;
    if (!g_present_aa_libs[index]) g_present_aa_libs[index] = [g_dev newLibraryWithSource:@(sources[index]) options:nil error:&error];
    id<MTLLibrary> lib = g_present_aa_libs[index];
    if (!lib) { MLOG("【红】 direct AA library: %s", error.localizedDescription.UTF8String); return nil; }
    id<MTLFunction> function;
    MTLFunctionConstantValues *constants = [MTLFunctionConstantValues new];
    for (int i = 0; i < 4; i++) { int on = i == g_present_aa - 2; [constants setConstantValue:&on type:MTLDataTypeInt atIndex:i]; }
    float width = w, height = h;
    [constants setConstantValue:&width type:MTLDataTypeFloat atIndex:4];
    [constants setConstantValue:&height type:MTLDataTypeFloat atIndex:5];
    // One pixel per lane keeps adjacent texture reads/writes contiguous;
    // GAL's unspecialized shader retains its original 4x4 tile contract.
    uint32_t pixels = 1;
    [constants setConstantValue:&pixels type:MTLDataTypeUInt atIndex:6];
    function = [lib newFunctionWithName:names[index] constantValues:constants error:&error];
    id<MTLComputePipelineState> pipeline = function ? [g_dev newComputePipelineStateWithFunction:function error:&error] : nil;
    if (!pipeline) MLOG("【红】 direct AA pipeline %s: %s", names[index].UTF8String, error.localizedDescription.UTF8String);
    return pipeline;
}
static NvPresentAA *present_aa_prepare(int slot, id<MTLTexture> src, const int crop[4]) {
    NSUInteger w = src.width, h = src.height;
    if (crop && (crop[2] || crop[3])) {
        if (crop[0] < 0 || crop[1] < 0 || crop[2] <= 0 || crop[3] <= 0 ||
            (uint64_t)crop[0] + crop[2] > w || (uint64_t)crop[1] + crop[3] > h) {
            MLOG("【红】 direct AA crop out of bounds"); return nil;
        }
        w = crop[2]; h = crop[3];
    }
    NvPresentAA *old = g_present_aa_slots[slot];
    if (old && old->input.width == w && old->input.height == h) return old;
    NvPresentAA *s = [NvPresentAA new];
    s->input = present_aa_texture(MTLPixelFormatBGRA8Unorm, w, h,
        MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget | MTLTextureUsagePixelFormatView);
    s->output = present_aa_texture(MTLPixelFormatBGRA8Unorm, w, h, MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite);
    s->size = [g_dev newBufferWithLength:2 * sizeof(float) options:MTLResourceStorageModeShared];
    s->cropUV = [g_dev newBufferWithLength:8 * sizeof(float) options:MTLResourceStorageModeShared];
    if (!s->input || !s->output || !s->size || !s->cropUV) { MLOG("【红】 direct AA texture/buffer allocation"); return nil; }
    float size[] = {(float)w, (float)h}; memcpy(s->size.contents, size, sizeof size);
    NSMutableArray *resources = [NSMutableArray arrayWithObjects:s->input, s->output, s->size, s->cropUV, nil];
    if (!g_present_aa_sampler) {
        MTLSamplerDescriptor *d = [MTLSamplerDescriptor new];
        d.minFilter = d.magFilter = MTLSamplerMinMagFilterLinear;
        d.sAddressMode = d.tAddressMode = MTLSamplerAddressModeClampToEdge; d.supportArgumentBuffers = YES;
        g_present_aa_sampler = [g_dev newSamplerStateWithDescriptor:d];
    }
    if (!g_present_aa_sampler) { MLOG("【红】 direct AA sampler allocation"); return nil; }
    s->edge = present_aa_texture(MTLPixelFormatRG8Unorm, w, h, MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite);
    s->blend = present_aa_texture(MTLPixelFormatRGBA8Unorm, w, h, MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite);
    s->linear = [s->input newTextureViewWithPixelFormat:MTLPixelFormatBGRA8Unorm_sRGB];
    if (!g_present_area) g_present_area = present_aa_lut(MTLPixelFormatRG8Unorm, 160, 560, k_aa_area, 320);
    if (!g_present_search) g_present_search = present_aa_lut(MTLPixelFormatR8Unorm, 64, 16, k_aa_search, 64);
    if (!s->edge || !s->blend || !s->linear || !g_present_area || !g_present_search) { MLOG("【红】 direct SMAA texture allocation"); return nil; }
    [resources addObjectsFromArray:@[s->edge, s->blend]];
    NSError *error = nil;
    if (!g_m3) s->cropTable = tab_new(1, 1, 1, &error);
    for (int p = 0; p < 3; p++) {
        s->pipelines[p] = present_aa_pipeline(p, w, h);
        if (!s->pipelines[p]) return nil;
        if (!g_m3) s->tables[p] = tab_new(1, 4, 3, &error);
        if (!g_m3 && (!s->tables[p] || !s->cropTable)) { MLOG("【红】 direct AA argument table: %s", error.localizedDescription.UTF8String); return nil; }
    }
    // The caller has waited for this slot's own GPU completion, not the present
    // ticket watermark (which can advance when the display link drops a frame).
    if (old) for (id<MTLResource> r in old->resources) res_remove(r);
    s->resources = resources;
    for (id<MTLResource> r in resources) res_add(r);
    g_present_aa_slots[slot] = s;
    return s;
}
static int present_aa_pass(id cb, NvPresentAA *s, int p, BOOL m4,
                           id<MTLTexture> a, id<MTLTexture> b, id<MTLTexture> c, id<MTLTexture> out) {
    id<MTLTexture> inputs[] = {a, b, c}; int count = c ? 3 : b ? 2 : 1;
    MTLSize threads = MTLSizeMake(out.width, out.height, 1);
    MTLSize group = MTLSizeMake(8, 8, 1);
    if (m4) {
        id e = enc_c_begin_on(cb, YES);
        if (!e) { MLOG("【红】 direct AA M4 encoder"); return 0; }
        id table = s->tables[p]; tab_buf(table, s->size, 0, 0);
        for (int i = 0; i < count; i++) { tab_tex(table, inputs[i], i); tab_samp(table, g_present_aa_sampler, i); }
        tab_tex(table, out, count);
        enc_c_table(e, table); [e setComputePipelineState:s->pipelines[p]];
        [e dispatchThreads:threads threadsPerThreadgroup:group];
        enc_end_on(e, YES);
    } else {
        id<MTLComputeCommandEncoder> e = enc_c_begin_on(cb, NO);
        if (!e) { MLOG("【红】 direct AA M3 encoder"); return 0; }
        [e setBuffer:s->size offset:0 atIndex:0];
        for (int i = 0; i < count; i++) { [e setTexture:inputs[i] atIndex:i]; [e setSamplerState:g_present_aa_sampler atIndex:i]; }
        [e setTexture:out atIndex:count]; [e setComputePipelineState:s->pipelines[p]];
        [e dispatchThreads:threads threadsPerThreadgroup:group]; enc_end_on(e, NO);
    }
    return 1;
}
static int present_aa_encode(id cb, NvPresentAA *s, BOOL m4) {
    return present_aa_pass(cb, s, 0, m4, s->input, nil, nil, s->edge) &&
        present_aa_pass(cb, s, 1, m4, s->edge, g_present_area, g_present_search, s->blend) &&
        present_aa_pass(cb, s, 2, m4, s->linear, s->blend, nil, s->output);
}
