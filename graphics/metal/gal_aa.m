// SMAA 1x：裁切翻转后的伽马编码帧，最终窗口缩放之前。
// 算法与 area/search 表来自仓库 Ryujinx，MSL 来源和许可见 shaders/AA-LICENSE.txt。
// 不带 FXAA（10-30 jhz：NVIDIA FXAA 3.11 声明里没有授权条款）：设置里的旧值 1（Fxaa）按 SMAA Medium 画。
#import "gal_internal.h"
#include "gal_aa_edge.h"
#include "gal_aa_blend.h"
#include "gal_aa_neighbour.h"
#include "gal_aa_lut.h"

NSString *gal_aa_msl(int index) {
    const char *const src[] = {k_aa_edge, k_aa_blend, k_aa_neighbour};
    return @(src[index]);
}

GAL_MTL4_ZONE_BEGIN
static struct { int w, h; id<MTLComputePipelineState> edge, blend, neighbour; } g_smaa[4];
static id<MTLTexture> g_edge, g_blend, g_area, g_search;
static id<MTLSamplerState> g_linear;
static id g_tables[3];

static id<MTLComputePipelineState> aa_pipeline(int helper, NSString *name, int w, int h, int quality) {
    NSError *error = nil;
    id<MTLLibrary> library = gal_helper_lib(helper, &error);
    if (!library) { GLOG("【红】抗锯齿辅助库载入失败：%s", error.localizedDescription.UTF8String); return nil; }
    MTLFunctionConstantValues *values = [MTLFunctionConstantValues new];
    for (int i = 0; i < 4; i++) { int on = i == quality; [values setConstantValue:&on type:MTLDataTypeInt atIndex:i]; }
    float width = w, height = h;
    [values setConstantValue:&width type:MTLDataTypeFloat atIndex:4];
    [values setConstantValue:&height type:MTLDataTypeFloat atIndex:5];
    id<MTLComputePipelineState> pipeline = gal_new_compute_pso(gal_be_compute_desc(gal_be_fn_desc(library, name), values), &error);
    if (!pipeline) GLOG("【红】抗锯齿管线 %s 建不出：%s", name.UTF8String, error.localizedDescription.UTF8String);
    return pipeline;
}

static id<MTLTexture> aa_texture(MTLPixelFormat format, int w, int h, const void *data, int row) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:w height:h mipmapped:NO];
    d.storageMode = data ? MTLStorageModeShared : MTLStorageModePrivate;
    d.usage = MTLTextureUsageShaderRead | (data ? 0 : MTLTextureUsageShaderWrite);
    id<MTLTexture> t = [g_gdev newTextureWithDescriptor:d];
    if (!t) { GLOG("【红】抗锯齿贴图建不出 %dx%d", w, h); return nil; }
    if (data) [t replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:data bytesPerRow:row];
    gal_res_add(t);
    return t;
}

static int aa_init(void) {
    if (g_linear) return 1;
    NSError *error = nil;
    for (int i = 0; i < 3; i++) {
        g_tables[i] = gal_be_table_new(g_gdev, 1, 4, 3, &error);
        if (!g_tables[i]) { GLOG("【红】抗锯齿参数表建不出：%s", error.localizedDescription.UTF8String); return 0; }
    }
    MTLSamplerDescriptor *sampler = [MTLSamplerDescriptor new];
    sampler.minFilter = sampler.magFilter = MTLSamplerMinMagFilterLinear;
    sampler.sAddressMode = sampler.tAddressMode = MTLSamplerAddressModeClampToEdge;
    sampler.supportArgumentBuffers = YES;
    g_linear = [g_gdev newSamplerStateWithDescriptor:sampler];
    return g_linear != nil;
}

static void aa_pass(id<MTLComputePipelineState> pso, int pass, uint64_t size, int w, int h,
                    id<MTLTexture> a, id<MTLTexture> b, id<MTLTexture> c, id<MTLTexture> output) {
    id table = g_tables[pass];
    gal_be_table_address(table, size, 0);
    gal_be_table_texture(table, a, 0);
    int index = 1;
    if (b) gal_be_table_texture(table, b, index++);
    if (c) gal_be_table_texture(table, c, index++);
    gal_be_table_texture(table, output, index);
    for (int i = 0; i < index; i++) gal_be_table_sampler(table, g_linear, i);
    // gal_cmp_enc 在相邻派发间加内存屏障，render→compute / compute→render 也由后端处理；Metal 3 参数绑定未合入时报红返回 nil（M3-6）。
    id e = gal_cmp_enc();
    if (e) gal_be_compute_dispatch(e, pso, table, MTLSizeMake((w + 3) / 4, (h + 3) / 4, 1), MTLSizeMake(8, 8, 1));
}

// 单测故障注入（tests/t_aa.c，P1-25）：1 = 入口即失败；2 = 边缘 / 混合两遍已录进计算编码器后、建线性视图处失败（编码器还开着）。缺省 0，只在这两处判
int gal_aa_test_fail;
int gal_aa_encode(id<MTLTexture> src, id<MTLTexture> dst, int mode) {
    int w = (int)src.width, h = (int)src.height;
    if (gal_aa_test_fail == 1 || !aa_init()) return 0;
    int quality = mode <= 1 ? 1 : mode - 2;   // 1 = the old Fxaa value: SMAA Medium
    if (g_smaa[quality].w != w || g_smaa[quality].h != h) {
        id<MTLComputePipelineState> edge = aa_pipeline(GH_SMAA_EDGE, @"aa_edge", w, h, quality);
        id<MTLComputePipelineState> blend = aa_pipeline(GH_SMAA_BLEND, @"aa_blend", w, h, quality);
        id<MTLComputePipelineState> neighbour = aa_pipeline(GH_SMAA_NEIGHBOUR, @"aa_neighbour", w, h, quality);
        if (!edge || !blend || !neighbour) return 0;
        if (g_smaa[quality].edge) {
            gal_release_later(g_smaa[quality].edge, 0); gal_release_later(g_smaa[quality].blend, 0); gal_release_later(g_smaa[quality].neighbour, 0);
        }
        g_smaa[quality].edge = edge; g_smaa[quality].blend = blend; g_smaa[quality].neighbour = neighbour;
        g_smaa[quality].w = w; g_smaa[quality].h = h;
    }
    if (!g_area) g_area = aa_texture(MTLPixelFormatRG8Unorm, 160, 560, k_aa_area, 320);
    if (!g_search) g_search = aa_texture(MTLPixelFormatR8Unorm, 64, 16, k_aa_search, 64);
    if (!g_area || !g_search) return 0;
    if (!g_edge || (int)g_edge.width != w || (int)g_edge.height != h) {
        if (g_edge) { gal_release_later(g_edge, 1); gal_release_later(g_blend, 1); }
        g_edge = aa_texture(MTLPixelFormatRG8Unorm, w, h, NULL, 0);
        g_blend = aa_texture(MTLPixelFormatRGBA8Unorm, w, h, NULL, 0);
    }
    if (!g_edge || !g_blend) return 0;
    uint64_t address;
    float *size = gal_transient(2 * sizeof(float), 16, &address); if (!size) return 0;
    size[0] = w; size[1] = h;
    aa_pass(g_smaa[quality].edge, 0, address, w, h, src, nil, nil, g_edge);
    aa_pass(g_smaa[quality].blend, 1, address, w, h, g_edge, g_area, g_search, g_blend);
    // SMAA 的边缘判定在 gamma 空间；最终邻域混合按原算法建议在线性空间。
    // sRGB 视图让硬件先解码再双线性过滤；compute 输出由 shader 编回 sRGB。
    id<MTLTexture> linear = gal_aa_test_fail == 2 ? nil : [src newTextureViewWithPixelFormat:MTLPixelFormatBGRA8Unorm_sRGB];
    if (!linear) { GLOG("【红】SMAA 线性采样视图建不出"); return 0; }
    aa_pass(g_smaa[quality].neighbour, 2, address, w, h, linear, g_blend, nil, dst);
    gal_release_later(linear, 0);
    gal_enc_end();
    return 1;
}
GAL_MTL4_ZONE_END
