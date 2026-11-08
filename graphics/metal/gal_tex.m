// GAL Metal 后端：贴图（第 3 块）——格式表 / 建与视图 / 读写回（含深度模板转换、贴图缓冲）/ 四种拷贝 / SetStorage / 采样器 / 贴图与图像数组。
// 数据布局（GetData / SetData，与 Ryujinx Vulkan 后端 CopyFromOrToBuffer 同）：级在外、层在内；每级 = 各层紧排；
//   行跨度 = align(ceil(宽/块宽) × 每块字节, 4)，行数 = ceil(高/块高)；3D 贴图一级 = 该级全部深度切片。
#import "gal_internal.h"
#include <pthread.h>
#include "gal_pstat.h"
#include <stdlib.h>
#include <string.h>

// ---------- GAL Format（Ryujinx.Graphics.GAL.Format 的声明顺序）→ Metal ----------
#include "gal_formats.h"

#include "gal_samp_caps.h"   // 采样器 LOD 偏置在本机 GPU 上原生生效没有（s2a_lodbias_native，直连同一份判法，#800）

// 三分量、缩放整数（Uscaled / Sscaled）、R4G4 等 Metal 没有的格式：Capabilities 里报不支持，Gpu 层自己转成支持的格式再交来，这里不映射。
GAL_MTL4_ZONE_BEGIN   // Metal 4 可用性区（gal_internal.h）
static const MTLPixelFormat k_fmt[F_COUNT] = {
    [F_R8Unorm] = MTLPixelFormatR8Unorm, [F_R8Snorm] = MTLPixelFormatR8Snorm, [F_R8Uint] = MTLPixelFormatR8Uint, [F_R8Sint] = MTLPixelFormatR8Sint,
    [F_R16Float] = MTLPixelFormatR16Float, [F_R16Unorm] = MTLPixelFormatR16Unorm, [F_R16Snorm] = MTLPixelFormatR16Snorm,
    [F_R16Uint] = MTLPixelFormatR16Uint, [F_R16Sint] = MTLPixelFormatR16Sint,
    [F_R32Float] = MTLPixelFormatR32Float, [F_R32Uint] = MTLPixelFormatR32Uint, [F_R32Sint] = MTLPixelFormatR32Sint,
    [F_R8G8Unorm] = MTLPixelFormatRG8Unorm, [F_R8G8Snorm] = MTLPixelFormatRG8Snorm, [F_R8G8Uint] = MTLPixelFormatRG8Uint, [F_R8G8Sint] = MTLPixelFormatRG8Sint,
    [F_R16G16Float] = MTLPixelFormatRG16Float, [F_R16G16Unorm] = MTLPixelFormatRG16Unorm, [F_R16G16Snorm] = MTLPixelFormatRG16Snorm,
    [F_R16G16Uint] = MTLPixelFormatRG16Uint, [F_R16G16Sint] = MTLPixelFormatRG16Sint,
    [F_R32G32Float] = MTLPixelFormatRG32Float, [F_R32G32Uint] = MTLPixelFormatRG32Uint, [F_R32G32Sint] = MTLPixelFormatRG32Sint,
    [F_R8G8B8A8Unorm] = MTLPixelFormatRGBA8Unorm, [F_R8G8B8A8Snorm] = MTLPixelFormatRGBA8Snorm,
    [F_R8G8B8A8Uint] = MTLPixelFormatRGBA8Uint, [F_R8G8B8A8Sint] = MTLPixelFormatRGBA8Sint,
    [F_R16G16B16A16Float] = MTLPixelFormatRGBA16Float, [F_R16G16B16A16Unorm] = MTLPixelFormatRGBA16Unorm, [F_R16G16B16A16Snorm] = MTLPixelFormatRGBA16Snorm,
    [F_R16G16B16A16Uint] = MTLPixelFormatRGBA16Uint, [F_R16G16B16A16Sint] = MTLPixelFormatRGBA16Sint,
    [F_R32G32B32A32Float] = MTLPixelFormatRGBA32Float, [F_R32G32B32A32Uint] = MTLPixelFormatRGBA32Uint, [F_R32G32B32A32Sint] = MTLPixelFormatRGBA32Sint,
    [F_S8Uint] = MTLPixelFormatStencil8, [F_D16Unorm] = MTLPixelFormatDepth16Unorm, [F_D32Float] = MTLPixelFormatDepth32Float,
    // D24S8 三种：Apple GPU 没有 Depth24Unorm_Stencil8，落到 D32FS8（数据进出由第 3 块做 D24S8 ↔ D32FS8 转换，同 Vulkan 后端 NeedsD24S8Conversion）
    [F_S8UintD24Unorm] = MTLPixelFormatDepth32Float_Stencil8, [F_D24UnormS8Uint] = MTLPixelFormatDepth32Float_Stencil8,
    [F_X8UintD24Unorm] = MTLPixelFormatDepth32Float_Stencil8, [F_D32FloatS8Uint] = MTLPixelFormatDepth32Float_Stencil8,
    [F_R8G8B8A8Srgb] = MTLPixelFormatRGBA8Unorm_sRGB,
    // 16 位打包格式：Metal 名字按低位在前（实测 B5G6R5 的 B 在 0–4 位），Vulkan 名字按高位在前。GAL 语义取 Vulkan 后端（VkFormat + 视图分量修正），
    // 这里取位布局相同的 Metal 格式，分量修正放在采样视图（fmt_perm）。R4G4B4A4 = Vulkan 回退 R4G4B4A4Pack16 + 旋转那一路。
    [F_R4G4B4A4Unorm] = MTLPixelFormatABGR4Unorm,
    [F_R5G5B5X1Unorm] = MTLPixelFormatBGR5A1Unorm, [F_R5G5B5A1Unorm] = MTLPixelFormatBGR5A1Unorm, [F_R5G6B5Unorm] = MTLPixelFormatB5G6R5Unorm,
    [F_R10G10B10A2Unorm] = MTLPixelFormatRGB10A2Unorm, [F_R10G10B10A2Uint] = MTLPixelFormatRGB10A2Uint,
    [F_R11G11B10Float] = MTLPixelFormatRG11B10Float, [F_R9G9B9E5Float] = MTLPixelFormatRGB9E5Float,
    [F_Bc1RgbaUnorm] = MTLPixelFormatBC1_RGBA, [F_Bc2Unorm] = MTLPixelFormatBC2_RGBA, [F_Bc3Unorm] = MTLPixelFormatBC3_RGBA,
    [F_Bc1RgbaSrgb] = MTLPixelFormatBC1_RGBA_sRGB, [F_Bc2Srgb] = MTLPixelFormatBC2_RGBA_sRGB, [F_Bc3Srgb] = MTLPixelFormatBC3_RGBA_sRGB,
    [F_Bc4Unorm] = MTLPixelFormatBC4_RUnorm, [F_Bc4Snorm] = MTLPixelFormatBC4_RSnorm, [F_Bc5Unorm] = MTLPixelFormatBC5_RGUnorm, [F_Bc5Snorm] = MTLPixelFormatBC5_RGSnorm,
    [F_Bc7Unorm] = MTLPixelFormatBC7_RGBAUnorm, [F_Bc7Srgb] = MTLPixelFormatBC7_RGBAUnorm_sRGB,
    [F_Bc6HSfloat] = MTLPixelFormatBC6H_RGBFloat, [F_Bc6HUfloat] = MTLPixelFormatBC6H_RGBUfloat,
    [F_Etc2RgbUnorm] = MTLPixelFormatETC2_RGB8, [F_Etc2RgbaUnorm] = MTLPixelFormatEAC_RGBA8, [F_Etc2RgbPtaUnorm] = MTLPixelFormatETC2_RGB8A1,
    [F_Etc2RgbSrgb] = MTLPixelFormatETC2_RGB8_sRGB, [F_Etc2RgbaSrgb] = MTLPixelFormatEAC_RGBA8_sRGB, [F_Etc2RgbPtaSrgb] = MTLPixelFormatETC2_RGB8A1_sRGB,
    [F_Astc4x4Unorm] = MTLPixelFormatASTC_4x4_LDR, [F_Astc5x4Unorm] = MTLPixelFormatASTC_5x4_LDR, [F_Astc5x5Unorm] = MTLPixelFormatASTC_5x5_LDR,
    [F_Astc6x5Unorm] = MTLPixelFormatASTC_6x5_LDR, [F_Astc6x6Unorm] = MTLPixelFormatASTC_6x6_LDR, [F_Astc8x5Unorm] = MTLPixelFormatASTC_8x5_LDR,
    [F_Astc8x6Unorm] = MTLPixelFormatASTC_8x6_LDR, [F_Astc8x8Unorm] = MTLPixelFormatASTC_8x8_LDR, [F_Astc10x5Unorm] = MTLPixelFormatASTC_10x5_LDR,
    [F_Astc10x6Unorm] = MTLPixelFormatASTC_10x6_LDR, [F_Astc10x8Unorm] = MTLPixelFormatASTC_10x8_LDR, [F_Astc10x10Unorm] = MTLPixelFormatASTC_10x10_LDR,
    [F_Astc12x10Unorm] = MTLPixelFormatASTC_12x10_LDR, [F_Astc12x12Unorm] = MTLPixelFormatASTC_12x12_LDR,
    [F_Astc4x4Srgb] = MTLPixelFormatASTC_4x4_sRGB, [F_Astc5x4Srgb] = MTLPixelFormatASTC_5x4_sRGB, [F_Astc5x5Srgb] = MTLPixelFormatASTC_5x5_sRGB,
    [F_Astc6x5Srgb] = MTLPixelFormatASTC_6x5_sRGB, [F_Astc6x6Srgb] = MTLPixelFormatASTC_6x6_sRGB, [F_Astc8x5Srgb] = MTLPixelFormatASTC_8x5_sRGB,
    [F_Astc8x6Srgb] = MTLPixelFormatASTC_8x6_sRGB, [F_Astc8x8Srgb] = MTLPixelFormatASTC_8x8_sRGB, [F_Astc10x5Srgb] = MTLPixelFormatASTC_10x5_sRGB,
    [F_Astc10x6Srgb] = MTLPixelFormatASTC_10x6_sRGB, [F_Astc10x8Srgb] = MTLPixelFormatASTC_10x8_sRGB, [F_Astc10x10Srgb] = MTLPixelFormatASTC_10x10_sRGB,
    [F_Astc12x10Srgb] = MTLPixelFormatASTC_12x10_sRGB, [F_Astc12x12Srgb] = MTLPixelFormatASTC_12x12_sRGB,
    [F_B5G6R5Unorm] = MTLPixelFormatB5G6R5Unorm, [F_B5G5R5A1Unorm] = MTLPixelFormatBGR5A1Unorm, [F_A1B5G5R5Unorm] = MTLPixelFormatA1BGR5Unorm,
    [F_B8G8R8A8Unorm] = MTLPixelFormatBGRA8Unorm, [F_B8G8R8A8Srgb] = MTLPixelFormatBGRA8Unorm_sRGB, [F_B10G10R10A2Unorm] = MTLPixelFormatBGR10A2Unorm,
    [F_A8B8G8R8Uint] = MTLPixelFormatRGBA8Uint,
};

MTLPixelFormat gal_fmt_mtl(int32_t f) { return (unsigned)f < F_COUNT ? k_fmt[f] : MTLPixelFormatInvalid; }
int gal_fmt_is_ds(int32_t f) {
    switch (f) {
        case F_D16Unorm: case F_D32Float: return 1;
        case F_S8Uint: return 2;
        case F_S8UintD24Unorm: case F_D24UnormS8Uint: case F_X8UintD24Unorm: case F_D32FloatS8Uint: return 3;
    }
    return 0;
}
int gal_fmt_ctype(int32_t f) {
    switch (f) {
        case F_R8Uint: case F_R16Uint: case F_R32Uint: case F_R8G8Uint: case F_R16G16Uint: case F_R32G32Uint: case F_R8G8B8Uint: case F_R16G16B16Uint:
        case F_R32G32B32Uint: case F_R8G8B8A8Uint: case F_R16G16B16A16Uint: case F_R32G32B32A32Uint: case F_R10G10B10A2Uint: case F_A8B8G8R8Uint: case F_S8Uint:
            return 1;
        case F_R8Sint: case F_R16Sint: case F_R32Sint: case F_R8G8Sint: case F_R16G16Sint: case F_R32G32Sint: case F_R8G8B8Sint: case F_R16G16B16Sint:
        case F_R32G32B32Sint: case F_R8G8B8A8Sint: case F_R16G16B16A16Sint: case F_R32G32B32A32Sint: case F_R10G10B10A2Sint:
            return 2;
    }
    return 0;
}

MTLPixelFormat gal_raw_uint_fmt(int bpp) {
    switch (bpp) { case 1: return MTLPixelFormatR8Uint; case 2: return MTLPixelFormatR16Uint; case 4: return MTLPixelFormatR32Uint;
                   case 8: return MTLPixelFormatRG32Uint; case 16: return MTLPixelFormatRGBA32Uint; }
    return MTLPixelFormatInvalid;
}

// 16 位打包格式的分量修正（对照 Vulkan TextureView 构造函数）：逻辑分量 c（0 R 1 G 2 B 3 A）落在 Metal 格式的物理分量 perm[c]。
//   R5G6B5 / R5G5B5A1 / R5G5B5X1：Vulkan 交换 R↔B；A1B5G5R5 / R4G4B4A4（R4G4B4A4Pack16 回退）：Vulkan 旋转 (R,G,B,A) ← (A,B,G,R)。
//   与 Vulkan 的差别：Vulkan 交换的是「交换通道的位置」，对恒等交换等价，对非恒等交换（如 (R,R,R,1)）会取错分量；这里按值映射（先查用户交换得逻辑分量，再映射到物理分量）。
//   X1：alpha 位无意义，采样时强制 1（同 Gpu 层自己的 CPU 转换 ConvertR5G5B5ToR8G8B8A8(forceAlpha)）。
static void fmt_perm(int32_t f, int perm[4], int *alpha_one) {
    perm[0] = 0; perm[1] = 1; perm[2] = 2; perm[3] = 3; *alpha_one = 0;
    switch (f) {
        case F_R5G5B5X1Unorm: *alpha_one = 1; /* fallthrough */
        case F_R5G6B5Unorm: case F_R5G5B5A1Unorm: perm[0] = 2; perm[2] = 0; break;
        case F_A1B5G5R5Unorm: case F_R4G4B4A4Unorm: perm[0] = 3; perm[1] = 2; perm[2] = 1; perm[3] = 0; break;
    }
}

// ---------- 贴图表 ----------
static gal_tex *g_tex; static uint32_t g_ntex, g_captex;
static uint32_t *g_tex_free; static uint32_t g_ntex_free, g_cap_free;
gal_tex *gal_tex_get(uint32_t tid) { return tid && tid < g_ntex && g_tex[tid].live ? &g_tex[tid] : NULL; }
static uint32_t tex_alloc(void) {   // 0 = 表扩不了（已报红），调用方按建失败返回 0
    if (g_ntex_free) return g_tex_free[--g_ntex_free];
    if (!g_ntex) g_ntex = 1;   // 0 = 空
    if (g_ntex >= g_captex) {
        uint32_t nc = g_captex ? g_captex * 2 : 1024; gal_tex *nt = gal_grow(g_tex, nc, sizeof *g_tex, "贴图表"); if (!nt) return 0;
        g_tex = nt; memset((void *)(g_tex + g_ntex), 0, (nc - g_ntex) * sizeof *g_tex); g_captex = nc;
    }
    return g_ntex++;
}

static int imax(int a, int b) { return a > b ? a : b; }
static int imin(int a, int b) { return a < b ? a : b; }
static int mipsz(int v, int l) { return imax(1, v >> l); }
static int is_compressed(const nxgal_tex_info *i) { return i->block_w > 1 || i->block_h > 1; }
// 图像原子（10-24 图形接口盘点静默 5）：Vulkan 后端里存储图像能做原子靠格式能力、不要用途位；Metal 要 MTLTextureUsageShaderAtomic（iOS 17 / macOS 14 起）。
//   照 Vulkan 语义：带着色器写用途、且是 Metal 支持贴图原子的 32 位整数格式（R32Uint / R32Sint）就加上。只给这两种：原子用途可能关掉贴图无损压缩
static MTLTextureUsage atomic_usage(MTLPixelFormat pf, MTLTextureUsage u) {
    return (u & MTLTextureUsageShaderWrite) && (pf == MTLPixelFormatR32Uint || pf == MTLPixelFormatR32Sint) ? MTLTextureUsageShaderAtomic : 0;
}
static int is_ms(const nxgal_tex_info *i) { return i->target == 5 || i->target == 6; }
static int is_3d(const nxgal_tex_info *i) { return i->target == 2; }

static MTLTextureType tex_type(int32_t target) {
    switch (target) {
        case 0: return MTLTextureType1D;   case 1: return MTLTextureType2D;   case 2: return MTLTextureType3D;
        case 3: return MTLTextureType1DArray; case 4: return MTLTextureType2DArray;
        case 5: return MTLTextureType2DMultisample; case 6: return MTLTextureType2DMultisampleArray;
        case 7: return MTLTextureTypeCube; case 8: return MTLTextureTypeCubeArray; case 9: return MTLTextureTypeTextureBuffer;
    }
    return MTLTextureType2D;
}
// 采样视图的交换通道：用户交换（SwizzleComponent：0 Zero 1 One 2 R 3 G 4 B 5 A）按值映射过格式分量修正
static MTLTextureSwizzleChannels smp_swz(const nxgal_tex_info *i) {
    int perm[4], a1; fmt_perm(i->format, perm, &a1);
    MTLTextureSwizzle o[4];
    for (int c = 0; c < 4; c++) {
        int s = i->swz[c];
        if (s == 0) o[c] = MTLTextureSwizzleZero;
        else if (s == 1) o[c] = MTLTextureSwizzleOne;
        else { int lc = (s >= 2 && s <= 5) ? s - 2 : c; o[c] = (lc == 3 && a1) ? MTLTextureSwizzleOne : (MTLTextureSwizzle)(MTLTextureSwizzleRed + perm[lc]); }
    }
    return MTLTextureSwizzleChannelsMake(o[0], o[1], o[2], o[3]);
}
static int swz_identity(MTLTextureSwizzleChannels s) {
    return s.red == MTLTextureSwizzleRed && s.green == MTLTextureSwizzleGreen && s.blue == MTLTextureSwizzleBlue && s.alpha == MTLTextureSwizzleAlpha;
}
// GAL 的 depth 对数组 / 立方体是层数（立方体 6 的倍数），对 3D 是深度
// 层数照 Ryujinx TextureCreateInfo.GetLayers：2D 数组 / 多重采样数组 / 立方体数组 = Depth，立方体 = 6（不看 Depth——10-18 动森进岛录像里立方体视图 Depth = 1，按 Depth 建视图触发 Metal 断言），
// 1D 数组 = Height（GAL 把 1D 数组的层放在高度上，同 OpenGL 后端 TexStorage2D(Texture1DArray, w, h)），其余 1
static int tex_layers(const nxgal_tex_info *i) {
    switch (i->target) { case 4: case 6: case 8: return i->depth; case 7: return 6; case 3: return i->height; }
    return 1;
}
static int depth_or_layers(const nxgal_tex_info *i) { return is_3d(i) ? i->depth : tex_layers(i); }

// 一律基于底层存储贴图建视图（视图的视图开 GPU 校验读出全 0）：level / slice 相对本贴图，内部加上 base 偏移
static id<MTLTexture> root_view(const gal_tex *t, MTLPixelFormat pf, MTLTextureType type, int level, int nlevels, int slice, int nslices, MTLTextureSwizzleChannels sw) {
    if (t->root.textureType == MTLTextureType3D) { slice = 0; nslices = 1; }
    if ((type == MTLTextureTypeCube || type == MTLTextureTypeCubeArray) && (nslices % 6 || (t->base_layer + slice) % 6)) {
        static int n; if (n++ < 4) GLOG("【红】立方体视图层范围不是 6 的整倍：父类型 %lu 层 %lu，视图 起 %d 层数 %d 目标 %d 宽高 %d×%d 深 %d（Metal 断言，拒建）",
            (unsigned long)t->root.textureType, (unsigned long)t->root.arrayLength, t->base_layer + slice, nslices, t->info.target, t->info.width, t->info.height, t->info.depth);
        return nil;
    }
    return [t->root newTextureViewWithPixelFormat:pf textureType:type levels:NSMakeRange(t->base_level + level, nlevels)
                                           slices:NSMakeRange(t->base_layer + slice, nslices) swizzle:sw];
}
static int view_slices(const nxgal_tex_info *i) { return is_3d(i) ? 1 : tex_layers(i); }
// 采样视图：恒等交换且不选模板平面时就是 tex 本身
static id<MTLTexture> make_smp(const gal_tex *t) {
    const nxgal_tex_info *i = &t->info;
    MTLTextureSwizzleChannels sw = smp_swz(i);
    MTLPixelFormat pf = t->tex.pixelFormat;
    if (gal_fmt_is_ds(i->format) == 3 && i->ds_mode == 1) pf = MTLPixelFormatX32_Stencil8;   // DepthStencilMode.Stencil：采样模板平面
    if (pf == t->tex.pixelFormat && swz_identity(sw)) return t->tex;
    id<MTLTexture> v = root_view(t, pf, t->tex.textureType, 0, (int)t->tex.mipmapLevelCount, 0, view_slices(i), sw);
    if (!v) { GLOG("【红】建采样视图失败：格式 %d 目标 %d 交换 %d%d%d%d", i->format, i->target, i->swz[0], i->swz[1], i->swz[2], i->swz[3]); return t->tex; }
    return v;
}

// 遍统计（NXGAL_PSTAT）：拷贝 / 读回 / 写入碰到的贴图一律按「读」记（部分写入要保留旧内容，保守）
static void tex_touch(uint32_t id) {
    gal_tex *t = gal_tex_get(id); if (!t) return;
    gal_pass_clears_touch(t->root);
    if (PSTAT_ON()) gal_pstat_use((__bridge void *)t->root, PS_READ, 0, 0);
}
// 未写先采样诊断（见 gal_internal.h）
uint64_t gal_draw_count(void);
int g_uw_on = -1;
static uint64_t g_uw_n, g_uw_tex;
static gal_tex *uw_root(uint32_t tid) { gal_tex *t = gal_tex_get(tid); for (int k = 0; t && t->parent && k < 8; k++) { gal_tex *p = gal_tex_get(t->parent); if (!p) break; t = p; } return t; }
static int uw_on(void) { if (g_uw_on < 0) { const char *v = getenv("NXGAL_UNWRITTEN_SAMPLE"); g_uw_on = !(v && v[0] == '0'); } return g_uw_on; }   // 缺省开（=0 关）
void gal_uw_write(uint32_t tid) { if (!uw_on() || !tid) return; gal_tex *r = uw_root(tid); if (r) r->uw_written = 1; }
void gal_uw_sample(uint32_t tid, const char *where) {
    if (!uw_on() || !tid) return; gal_tex *r = uw_root(tid); if (!r || r->uw_written) return;
    g_uw_n++;
    if (!r->uw_rep) { r->uw_rep = 1; g_uw_tex++;
        GLOG("【未写先采样】第 %llu 张：贴图 %u（底层）%dx%dx%d 格式 %d 目标 %d 级 %d，经 %s 绑定采样时从没被写过；累计采样 %llu 次，绘制号 %llu",
             (unsigned long long)g_uw_tex, tid, r->info.width, r->info.height, r->info.depth, r->info.format, r->info.target, r->info.levels, where,
             (unsigned long long)g_uw_n, (unsigned long long)gal_draw_count()); }
}

NXGAL_API uint32_t nxgal_tex_create(const nxgal_tex_info *info_in) { GAL_API_LOCK();
    // 级数截到尺寸允许的上限 ⌊log2(最大边)⌋ + 1（Metal 校验；Ryujinx 渲染目标缩放 S2A_RES_SCALE 时 128 级链缩成 118 仍报 8 级 → 断言中止）。
    // 存表的 info 也用截过的，之后按级数的视图 / 上传 / 拷贝都不越界；超出的那级上传按已有级数判断跳过
    nxgal_tex_info ci = *info_in; const nxgal_tex_info *info = &ci;
    { int m = ci.width > ci.height ? ci.width : ci.height; if (ci.target == 2 && ci.depth > m) m = ci.depth; int ml = 1; while (m > 1) { m >>= 1; ml++; } if (ci.levels > ml) ci.levels = ml; }
    gal_pass_rt_dirty();
    g_obj_gen++;   // 同号换对象：按集复用的参数缓冲作废
    MTLPixelFormat pf = gal_fmt_mtl(info->format);
    if (pf == MTLPixelFormatInvalid) { GLOG("【红】贴图格式 %d 没有 Metal 映射（%dx%d 目标 %d）", info->format, info->width, info->height, info->target); return 0; }
    if (info->target == 9) {   // 贴图缓冲：Metal 贴图在 SetStorage 时由缓冲直接建
        uint32_t tid = tex_alloc(); if (!tid) return 0;
        g_tex[tid] = (gal_tex){.info = *info, .live = 1, .gen = 1};
        return tid;
    }
    @autoreleasepool {
        MTLTextureDescriptor *d = [MTLTextureDescriptor new];
        d.textureType = tex_type(info->target); d.pixelFormat = pf;
        d.width = info->width; d.height = info->target == 0 || info->target == 3 ? 1 : info->height;
        d.depth = info->target == 2 ? info->depth : 1;
        int layers = tex_layers(info);
        d.arrayLength = (info->target == 7 || info->target == 8) ? layers / 6 : layers;
        if (info->target == 7) d.arrayLength = 1;
        d.mipmapLevelCount = info->levels > 0 ? info->levels : 1;
        d.sampleCount = info->samples > 0 ? info->samples : 1;
        d.storageMode = MTLStorageModePrivate;
        MTLTextureUsage u = MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
        int compressed = is_compressed(info);
        if (!compressed) u |= MTLTextureUsageRenderTarget;
        if (!compressed && !gal_fmt_is_ds(info->format) && d.sampleCount == 1) u |= MTLTextureUsageShaderWrite;
        u |= atomic_usage(pf, u);
        d.usage = u;   // 底层贴图恒等交换：交换通道只在采样视图上（Metal：带交换的贴图不能有渲染目标 / 着色器写用途）
        id<MTLTexture> t; { RS_SCOPE(RS_TEX); t = [g_gdev newTextureWithDescriptor:d]; }
        if (t) RS_BYTES(RS_TEX, t.allocatedSize);
        if (!t) { GLOG("【红】建贴图失败：格式 %d %dx%dx%d 级 %d 目标 %d", info->format, info->width, info->height, info->depth, info->levels, info->target); return 0; }
        gal_res_add(t);
        uint32_t tid = tex_alloc(); if (!tid) { gal_res_remove(t); return 0; }
        g_tex[tid] = (gal_tex){.tex = t, .info = *info, .live = 1, .gen = 1, .root = t};
        g_tex[tid].smp = make_smp(&g_tex[tid]);
        gal_tex_rid(&g_tex[tid]);
        return tid;
    }
}

NXGAL_API uint32_t nxgal_tex_view(uint32_t parent, const nxgal_tex_info *info_in, int32_t first_layer, int32_t first_level) { GAL_API_LOCK();
    gal_pass_rt_dirty();
    g_obj_gen++;   // 同号换对象：按集复用的参数缓冲作废
    gal_tex *p = gal_tex_get(parent); if (!p) { GRED_ONCE("建视图：父贴图 %u 无效", parent); return 0; }
    // 父贴图级数可能被截过（见 nxgal_tex_create）：视图的起始级与级数截到父贴图范围内
    nxgal_tex_info ci = *info_in; const nxgal_tex_info *info = &ci;
    { int pl = p->info.levels > 0 ? p->info.levels : 1; if (first_level >= pl) first_level = pl - 1; if (ci.levels > pl - first_level) ci.levels = pl - first_level; }
    MTLPixelFormat pf = gal_fmt_mtl(info->format);
    if (pf == MTLPixelFormatInvalid) { GLOG("【红】视图格式 %d 没有 Metal 映射", info->format); return 0; }
    if (p->info.target == 9 || info->target == 9) { GLOG("【红】贴图缓冲不能建视图（父 %u）", parent); return 0; }
    // Metal 不能在压缩 / 非压缩格式之间建视图（调试层直接断言）：先拦下
    if (is_compressed(&p->info) != is_compressed(info) || (is_compressed(info) && (p->info.block_w != info->block_w || p->info.block_h != info->block_h))) {
        GLOG("【红】压缩与非压缩格式之间不能建视图：父 %u 格式 %d → %d", parent, p->info.format, info->format); return 0;
    }
    @autoreleasepool {
        gal_tex tmp = {.root = p->root, .base_layer = p->base_layer + first_layer, .base_level = p->base_level + first_level, .info = *info};
        id<MTLTexture> t = root_view(&tmp, pf, tex_type(info->target), 0, info->levels > 0 ? info->levels : 1, 0, view_slices(info), MTLTextureSwizzleChannelsDefault);
        if (!t) { GLOG("【红】建视图失败：父 %u 格式 %d→%d 目标 %d 层 %d 级 %d+%d", parent, p->info.format, info->format, info->target, first_layer, first_level, info->levels); return 0; }
        uint32_t tid = tex_alloc(); if (!tid) return 0;
        tmp.tex = t; tmp.parent = parent; tmp.live = 1; tmp.gen = 1;
        g_tex[tid] = tmp;
        p = NULL;   // tex_alloc 可能搬动了表
        g_tex[tid].smp = make_smp(&g_tex[tid]);
        gal_tex_rid(&g_tex[tid]);
        return tid;
    }
}

NXGAL_API void nxgal_tex_release(uint32_t tid) { GAL_API_LOCK();
    gal_pass_rt_dirty();
    { gal_tex *rt_ = gal_tex_get(tid); if (rt_ && gal_pass_clears_any()) gal_pass_clears_touch(rt_->root); }   // 同底层的别的视图可能还要读：放之前落实
    g_obj_gen++;   // 同号换对象：按集复用的参数缓冲作废
    gal_tex *t = gal_tex_get(tid); if (!t) return;
    if (t->smp && t->smp != t->tex) gal_release_later(t->smp, 0);
    if (t->tex) gal_release_later(t->tex, t->parent == 0 && t->info.target != 9);   // 视图 / 贴图缓冲不进驻留集（底层贴图 / 缓冲在）
    t->tex = nil; t->smp = nil; t->root = nil; t->live = 0; t->rid_tex = t->rid_smp = 0;
    if (g_ntex_free == g_cap_free) { g_cap_free = g_cap_free ? g_cap_free * 2 : 1024; g_tex_free = realloc(g_tex_free, g_cap_free * sizeof *g_tex_free); }
    g_tex_free[g_ntex_free++] = tid;
}

// ---------- 读写回 ----------
// 数据布局（GetData / SetData，与 Ryujinx Vulkan 后端 CopyFromOrToBuffer 同）：级在外、层在内；每级 = 各层紧排；
//   行跨度 = align(ceil(宽/块宽) × 每块字节, 4)，行数 = ceil(高/块高)；3D 贴图一级 = 该级全部深度切片。
// 深度模板（Metal 落到 Depth32Float_Stencil8 的五种：D24S8 三种 + D32FloatS8Uint）：Metal 只能按平面拷（深度 4 字节浮点、模板 1 字节），
//   CPU 侧在 GAL 布局与两平面之间转换（对照 Vulkan NeedsD24S8Conversion / FormatConverter，布局按 OpenGL 后端逐格式核对）：
//   D24UnormS8Uint：v = d24 << 8 | s；S8UintD24Unorm：v = s << 24 | d24（OpenGL 后端上传前 ConvertS8D24ToD24S8 旋转 8 位；Vulkan 转换器三种一律按 d24<<8|s，此格式与之不同）；
//   X8UintD24Unorm：v = d24 << 8（低 8 位丢弃，读回为 0）；D32FloatS8Uint：8 字节 {float 深度, uint32 模板（低 8 位）}。
//   d24 ↔ 浮点：f = d24 / 16777215，回转 round(f × 16777215)（Vulkan 转换器是截断；按 unorm 转换规则取就近，24 位全值往返无损）。
static int ds_planes(const nxgal_tex_info *i) { return gal_fmt_is_ds(i->format) == 3; }
static void ds_to_planes(int32_t f, const uint8_t *src, float *dep, uint8_t *st, size_t n) {
    for (size_t k = 0; k < n; k++) {
        uint32_t v; memcpy(&v, src + k * (f == F_D32FloatS8Uint ? 8 : 4), 4);
        if (f == F_D32FloatS8Uint) { memcpy(&dep[k], &v, 4); uint32_t s; memcpy(&s, src + k * 8 + 4, 4); st[k] = (uint8_t)s; continue; }
        uint32_t d24 = f == F_S8UintD24Unorm ? (v & 0xffffff) : (v >> 8);
        st[k] = f == F_S8UintD24Unorm ? (uint8_t)(v >> 24) : f == F_X8UintD24Unorm ? 0 : (uint8_t)v;
        dep[k] = (float)((double)d24 / 16777215.0);
    }
}
static uint32_t d24_of(float f) { double d = f < 0 ? 0 : f > 1 ? 1 : f; if (f != f) d = 0; return (uint32_t)llround(d * 16777215.0); }
static void ds_from_planes(int32_t f, const float *dep, const uint8_t *st, uint8_t *dst, size_t n) {
    for (size_t k = 0; k < n; k++) {
        if (f == F_D32FloatS8Uint) { uint32_t s = st[k]; memcpy(dst + k * 8, &dep[k], 4); memcpy(dst + k * 8 + 4, &s, 4); continue; }
        uint32_t d24 = d24_of(dep[k]), v = f == F_S8UintD24Unorm ? ((uint32_t)st[k] << 24) | d24 : f == F_X8UintD24Unorm ? d24 << 8 : (d24 << 8) | st[k];
        memcpy(dst + k * 4, &v, 4);
    }
}

typedef struct { int w, h, d; uint64_t stride, size2d; } lvl_geo;   // 某级的尺寸与紧排几何（size2d = 一层）
static lvl_geo geo(const nxgal_tex_info *i, int level) {
    lvl_geo g; g.w = mipsz(i->width, level); g.h = mipsz(i->height, level); g.d = is_3d(i) ? mipsz(i->depth, level) : 1;
    int bw = imax(1, i->block_w), bh = imax(1, i->block_h);
    g.stride = (((uint64_t)((g.w + bw - 1) / bw) * i->bpp) + 3) & ~3ull;
    g.size2d = g.stride * ((g.h + bh - 1) / bh);
    return g;
}
// 一段：Metal 子资源（相对本贴图的级 / 层，3D 用 z）+ 在 GAL 紧排数据里的位置
typedef struct { int level, slice, x, y, z, w, h, d; uint64_t off, stride, img; } sub;
static sub *subs_of(const nxgal_tex_info *i, int32_t layer, int32_t level, const nxgal_rect *rg, int *n, uint64_t *total) {
    int levels = imax(1, i->levels), layers = tex_layers(i);
    sub *s = malloc(sizeof *s * (size_t)(layer < 0 || level < 0 ? levels * layers : 1)); int k = 0; uint64_t off = 0;
    if (rg) {
        int bw = imax(1, i->block_w), bh = imax(1, i->block_h);
        uint64_t stride = (((uint64_t)((rg->w + bw - 1) / bw) * i->bpp) + 3) & ~3ull, img = stride * ((rg->h + bh - 1) / bh);
        s[k++] = (sub){level, is_3d(i) ? 0 : layer, rg->x, rg->y, is_3d(i) ? layer : 0, rg->w, rg->h, 1, 0, stride, img}; off = img;
    } else if (layer < 0 || level < 0) {
        for (int l = 0; l < levels; l++) { lvl_geo g = geo(i, l);
            if (is_3d(i)) { s[k++] = (sub){l, 0, 0, 0, 0, g.w, g.h, g.d, off, g.stride, g.size2d}; off += g.size2d * g.d; }
            else for (int L = 0; L < layers; L++) { s[k++] = (sub){l, L, 0, 0, 0, g.w, g.h, 1, off, g.stride, g.size2d}; off += g.size2d; } }
    } else { lvl_geo g = geo(i, level); s[k++] = (sub){level, is_3d(i) ? 0 : layer, 0, 0, is_3d(i) ? layer : 0, g.w, g.h, 1, 0, g.stride, g.size2d}; off = g.size2d; }
    *n = k; *total = off; return s;
}
// 绝对子资源（相对底层贴图）：3D 不加层偏移
static NSUInteger abs_slice(const gal_tex *t, int slice) { return t->root.textureType == MTLTextureType3D ? 0 : (NSUInteger)(t->base_layer + slice); }
static NSUInteger abs_level(const gal_tex *t, int level) { return (NSUInteger)(t->base_level + level); }
// 一段与暂存缓冲之间的拷贝（对底层贴图按绝对子资源拷，不经视图）
// 遍内贴图上传挪到遍前段（帧级调度，帧率能耗线 10-21）：nxgal_tex_set_data 判过（渲染遍开着、目标贴图本遍没用过、数据在 CPU 暂存里）就置 1，
// 这次的缓冲→贴图拷贝录进遍前段（排在本遍之前、更早各遍之后），本遍不收；遍前段没开照旧录进在录流
static int g_up_pre;
static void up_pre_end(void *p) { (void)p; g_up_pre = 0; }
uint64_t g_texup_n[2];   // 贴图上传次数：[0] 在录流 [1] 遍前段
static void sub_copy(const gal_tex *t, const sub *s, id<MTLBuffer> b, uint64_t off, uint64_t stride, uint64_t img, MTLBlitOption opt, int to_buf) {
    id e = to_buf == 2 ? gal_readback_enc() : !to_buf && g_up_pre ? gal_prepass_enc() : nil;   // to_buf：0 缓冲→贴图 1 贴图→缓冲（GPU 流内）2 读回（可能在非录制线程，见 gal_readback_enc）
    if (!to_buf && g_up_pre) g_texup_n[e != nil]++;
    if (!e) e = gal_blit_enc();
    MTLOrigin o = MTLOriginMake(s->x, s->y, s->z); MTLSize sz = MTLSizeMake(s->w, s->h, s->d);
    if (to_buf) [e copyFromTexture:t->root sourceSlice:abs_slice(t, s->slice) sourceLevel:abs_level(t, s->level) sourceOrigin:o sourceSize:sz toBuffer:b
                 destinationOffset:off destinationBytesPerRow:stride destinationBytesPerImage:img options:opt];
    else [e copyFromBuffer:b sourceOffset:off sourceBytesPerRow:stride sourceBytesPerImage:img sourceSize:sz toTexture:t->root
          destinationSlice:abs_slice(t, s->slice) destinationLevel:abs_level(t, s->level) destinationOrigin:o options:opt];
}
static id<MTLBuffer> staging(uint64_t len) {
    id<MTLBuffer> b; { RS_SCOPE(RS_STAGING); b = [g_gdev newBufferWithLength:len ? len : 4 options:MTLResourceStorageModeShared]; } RS_BYTES(RS_STAGING, len);
    if (!b) { GLOG("【红】建 %llu 字节暂存缓冲失败（本次贴图读写跳过）：%s", (unsigned long long)len, gal_mem_note()); return nil; }   // 调用方都判 nil：分配失败不写空指针（10-20 暗黑3 iPhone 第 1716 帧 memmove 空指针）
    gal_res_add(b); return b;
}

// 贴图缓冲的读写直接落到挂着的缓冲（同 Vulkan TextureBuffer.GetData / SetData → 缓冲读写）
static uint64_t tbuf_io(gal_tex *t, void *out, const void *in, uint64_t len) {
    if (!t->tex) { GRED_ONCE("贴图缓冲还没 SetStorage 就读写"); return 0; }
    uint64_t moff; id<MTLBuffer> b = gal_buf_mtl(t->storage.buf, t->storage.offset, &moff); if (!b) return 0;
    uint64_t n = (uint64_t)t->storage.size; if (!out && !in) return n;
    if (len < n) n = len;
    id<MTLBuffer> s = staging(n); if (!s) return 0;
    if (in) { memcpy(s.contents, in, n); [gal_blit_enc() copyFromBuffer:s sourceOffset:0 toBuffer:b destinationOffset:moff size:n]; gal_release_later(s, 1); return n; }
    [gal_readback_enc() copyFromBuffer:b sourceOffset:moff toBuffer:s destinationOffset:0 size:n];
    gal_readback_finish(); memcpy(out, s.contents, n); gal_res_remove(s);
    return n;
}

// 调度测算（gal_pstat.h SW_*）：贴图本遍被写过（当前附件算写）/ 被读或写过
static const void *sw_root(uint32_t tid) { gal_tex *t = gal_tex_get(tid); return t ? (__bridge const void *)t->root : NULL; }
static int sw_tex_wr(uint32_t tid) { const void *r = sw_root(tid); return r && ((gal_sw_pass_open() && gal_pass_is_attachment((__bridge id<MTLTexture>)r)) || gal_sw_hit(r, 1)); }
static int sw_tex_rw(uint32_t tid) { const void *r = sw_root(tid); return r && (sw_tex_wr(tid) || gal_sw_hit(r, 0)); }
NXGAL_API uint64_t nxgal_tex_get_data(uint32_t tid, int32_t layer, int32_t level, void *out, uint64_t out_len) { GAL_API_LOCK();
    SW_SCOPE(SW_READBACK, 1);
    tex_touch(tid);   // 碰到的贴图有挂起清屏先落实（只落实涉及的，别的继续挂着等下次当附件吃掉）
    gal_tex *t = gal_tex_get(tid); if (!t) { GRED_ONCE("读回：贴图 %u 无效", tid); return 0; }
    if (t->info.target == 9) return tbuf_io(t, out, NULL, out_len);
    nxgal_tex_info info = t->info; const nxgal_tex_info *i = &info;
    int n; uint64_t total; sub *s = subs_of(i, layer, level, NULL, &n, &total);
    if (!out) { free(s); return total; }
    if (out_len < total) { GLOG("【红】读回缓冲太小：贴图 %u 要 %llu 字节，给 %llu", tid, (unsigned long long)total, (unsigned long long)out_len); free(s); return 0; }
    @autoreleasepool {
        if (!ds_planes(i)) {
            id<MTLBuffer> b = staging(total); if (!b) { free(s); return 0; }
            for (int k = 0; k < n; k++) sub_copy(t, &s[k], b, s[k].off, s[k].stride, s[k].img, MTLBlitOptionNone, 2);
            gal_readback_finish(); memcpy(out, b.contents, total); gal_res_remove(b);
        } else {
            uint64_t px = 0; for (int k = 0; k < n; k++) px += (uint64_t)s[k].w * s[k].h * s[k].d;
            id<MTLBuffer> b = staging(px * 5); if (!b) { free(s); return 0; }
            uint64_t p = 0;
            for (int k = 0; k < n; k++) { uint64_t m = (uint64_t)s[k].w * s[k].h;
                sub_copy(t, &s[k], b, p * 4, s[k].w * 4, m * 4, MTLBlitOptionDepthFromDepthStencil, 2);
                sub_copy(t, &s[k], b, px * 4 + p, s[k].w, m, MTLBlitOptionStencilFromDepthStencil, 2); p += m * s[k].d; }
            gal_readback_finish();
            p = 0;
            for (int k = 0; k < n; k++) { uint64_t m = (uint64_t)s[k].w * s[k].h * s[k].d;
                ds_from_planes(i->format, (const float *)b.contents + p, (const uint8_t *)b.contents + px * 4 + p, (uint8_t *)out + s[k].off, m); p += m; }
            gal_res_remove(b);
        }
    }
    free(s);
    return total;
}

// ---------- 上传租约（帧率能耗线 10-22，巫师3 换场景分配方案 B）----------
// Gpu 层转贴图格式 / 线程渲染器传缓冲数据时，直接写进这里租出的共享 Metal 内存（GPU 模拟线程上租，不拿 API 锁），
// 交给 nxgal_tex_set_data_lease / nxgal_buf_set_data_lease 时渲染器直接拿它当暂存（贴图）或从它拷（缓冲）——省掉托管数组（换场景帧 GPU 模拟线程
// 几十 MB 分配）和一次托管 → 暂存的拷贝。
// 内存：≤ 1 MB 的租约从 4 MB 共享块里按 256 字节对齐切（每块记未完成租约数：贴图租约 GPU 用完（挂在提交栅栏上的哨兵）、缓冲租约 CPU 拷完、
// 退租时减一）；块切满退役，未完成归零即空闲，下次交付时在渲染线程上放掉、不留空闲块（旧路的暂存缓冲用完即放，留着就比旧路
// 多占 Metal：八方2 开 / 关租约同一时刻 384 / 376 MB、巫师3 150 秒多出的里有 8 MB 是常驻块；放掉后常驻只剩在切的 1 块 4 MB，
// 建缓冲次数仍远少于旧路每次上传建一个暂存缓冲）。> 1 MB 的租约用独立缓冲。
// 10-22 第一版每个租约一块独立缓冲：巫师3 换场景几千次小上传各占一块，渲染线程队列里排着的全都活着，Metal 已分配第 30 秒 1088 MB（旧路 91 MB）、
// 低区耗尽、托管分配 OutOfMemory（w3_alloc/r3）。块内子分配后同时存活的只剩块数。失败路径 nxgal_upload_drop 退租。
#define UL_CHUNK (4u << 20)
#define M_BUF(p) ((__bridge id<MTLBuffer>)(p))
#define UL_BIG (1u << 20)
#define UL_KEEP 0
typedef struct { void *buf; uint32_t used, pend; uint8_t state, resident; } ul_chunk;   // state：0 空 1 在切 2 已退役 3 空闲
typedef struct { void *buf; int32_t chunk; uint32_t off; uint64_t len; } ul_ent;          // chunk < 0：独立缓冲（buf 持有）
static pthread_mutex_t g_ul_mu = PTHREAD_MUTEX_INITIALIZER;
static ul_chunk *g_ulc; static int g_nulc, g_capulc, g_ulc_cur = -1;
static ul_ent *g_ul; static uint32_t g_nul = 1, g_cap_ul; static uint32_t *g_ul_free; static uint32_t g_nul_free, g_cap_ul_free;
static uint64_t g_ul_rents;
static uint64_t g_ul_generation;
static void ul_chunk_dec(int c) {   // 调用方持 g_ul_mu
    ul_chunk *k = &g_ulc[c]; if (k->pend) k->pend--;
    if (k->state == 2 && !k->pend) k->state = 3;
}
@interface GalUlSentinel : NSObject { @public int chunk; uint64_t generation; } @end
@implementation GalUlSentinel
- (void)dealloc { pthread_mutex_lock(&g_ul_mu); if (generation == g_ul_generation && chunk >= 0 && chunk < g_nulc) ul_chunk_dec(chunk); pthread_mutex_unlock(&g_ul_mu); }
@end
// 切一段（持 g_ul_mu）：当前块放不下就退役它，换空闲块或新建
static int ul_carve(uint64_t len, uint32_t *off) {
    uint32_t need = (uint32_t)((len + 255) & ~255ull);
    if (g_ulc_cur >= 0 && g_ulc[g_ulc_cur].used + need > UL_CHUNK) { ul_chunk *k = &g_ulc[g_ulc_cur]; k->state = k->pend ? 2 : 3; g_ulc_cur = -1; }
    if (g_ulc_cur < 0) {
        int pick = -1;
        for (int c = 0; c < g_nulc; c++) if (g_ulc[c].state == 3) { pick = c; break; }
        if (pick < 0) {
            id<MTLBuffer> b = [g_gdev newBufferWithLength:UL_CHUNK options:MTLResourceStorageModeShared];
            if (!b) return -1;
            for (int c = 0; c < g_nulc && pick < 0; c++) if (g_ulc[c].state == 0) pick = c;
            if (pick < 0) { if (g_nulc == g_capulc) { g_capulc = g_capulc ? g_capulc * 2 : 16; g_ulc = realloc(g_ulc, g_capulc * sizeof *g_ulc); } pick = g_nulc++; }
            g_ulc[pick] = (ul_chunk){(void *)CFBridgingRetain(b), 0, 0, 0, 0};
        }
        g_ulc[pick].state = 1; g_ulc[pick].used = 0; g_ulc_cur = pick;
    }
    ul_chunk *k = &g_ulc[g_ulc_cur]; *off = k->used; k->used += need; k->pend++;
    return g_ulc_cur;
}
// 租约四个入口由 GPU 模拟线程 / 渲染线程（C# 线程，没有释放池）直接调：函数体各包一层 @autoreleasepool。
// 建缓冲（newBufferWithLength）和取租约两处 Metal / ARC 都会把缓冲放进自动释放池，没有池就一直不放
// （10-22 八方2 开租约 Metal 已分配多约 75 MB、不在驻留集；t_tex「租约独立缓冲」20 × 2 MB 多 40.0 MB，只包其中一处仍是 40.0 MB）
NXGAL_API uint32_t nxgal_upload_rent(uint64_t len, void **cpu) { @autoreleasepool {
    if (!len) len = 4;
    id<MTLBuffer> big = nil;
    if (len > UL_BIG) { big = [g_gdev newBufferWithLength:len options:MTLResourceStorageModeShared]; if (!big) { *cpu = NULL; return 0; } }
    pthread_mutex_lock(&g_ul_mu);
    ul_ent e = {NULL, -1, 0, len};
    if (big) { e.buf = (void *)CFBridgingRetain(big); *cpu = big.contents; }
    else {
        int c = ul_carve(len, &e.off);
        if (c < 0) { pthread_mutex_unlock(&g_ul_mu); GLOG("【红】上传租约：建 %u 字节共享块失败（退回旧路）：%s", UL_CHUNK, gal_mem_note()); *cpu = NULL; return 0; }
        e.chunk = c; *cpu = (uint8_t *)M_BUF(g_ulc[c].buf).contents + e.off;
    }
    uint32_t lid;
    if (g_nul_free) lid = g_ul_free[--g_nul_free];
    else { if (g_nul >= g_cap_ul) { g_cap_ul = g_cap_ul ? g_cap_ul * 2 : 256; g_ul = realloc(g_ul, g_cap_ul * sizeof *g_ul); } lid = g_nul++; }
    g_ul[lid] = e;
    uint64_t k = ++g_ul_rents; int nc = g_nulc;
    pthread_mutex_unlock(&g_ul_mu);
    if (!(k & (k - 1))) GLOG("上传租约：第 %llu 次（本次 %llu 字节；共享块 %d 个）", (unsigned long long)k, (unsigned long long)len, nc);
    return lid;
} }
// 取出租约（持 g_ul_mu 内完成）：返回 Metal 缓冲与偏移；*chunk = 所在块（< 0 = 独立缓冲，返回值持有它）
static id<MTLBuffer> ul_take(uint32_t lid, uint64_t *len, uint32_t *off, int *chunk) {
    id<MTLBuffer> b = nil; *len = 0; *off = 0; *chunk = -1;   // 无效 / 已交的租约：调用方据 nil 报红，块号 -1 不交还
    if (!lid) return nil;
    pthread_mutex_lock(&g_ul_mu);
    if (lid && lid < g_nul && (g_ul[lid].buf || g_ul[lid].chunk >= 0)) {
        ul_ent e = g_ul[lid]; g_ul[lid] = (ul_ent){NULL, -1, 0, 0};
        *len = e.len; *off = e.off; *chunk = e.chunk;
        b = e.chunk < 0 ? (__bridge_transfer id<MTLBuffer>)e.buf : M_BUF(g_ulc[e.chunk].buf);
        if (g_nul_free >= g_cap_ul_free) { g_cap_ul_free = g_cap_ul_free ? g_cap_ul_free * 2 : 256; g_ul_free = realloc(g_ul_free, g_cap_ul_free * sizeof *g_ul_free); }
        g_ul_free[g_nul_free++] = lid;
    }
    pthread_mutex_unlock(&g_ul_mu);
    return b;
}
static void ul_done_now(int chunk) { if (chunk < 0) return; pthread_mutex_lock(&g_ul_mu); ul_chunk_dec(chunk); pthread_mutex_unlock(&g_ul_mu); }
// 渲染线程（持 API 锁）：空闲块超过 UL_KEEP 的放掉（驻留集里的先移出）
static void ul_trim(void) {
    pthread_mutex_lock(&g_ul_mu);
    int idle = 0; for (int c = 0; c < g_nulc; c++) idle += g_ulc[c].state == 3;
    for (int c = 0; c < g_nulc && idle > UL_KEEP; c++) if (g_ulc[c].state == 3) {
        id<MTLBuffer> b = (__bridge_transfer id<MTLBuffer>)g_ulc[c].buf;
        if (g_ulc[c].resident) gal_res_remove(b);
        g_ulc[c] = (ul_chunk){0}; idle--; b = nil;
    }
    pthread_mutex_unlock(&g_ul_mu);
}
// 地址账（诊断，gal_buf_va_note 拼进「地址余量」行）：共享块按状态计数、未交租约个数与字节（共享块内 / 独立缓冲）
void gal_upload_va_note(char *o, size_t n) {
    pthread_mutex_lock(&g_ul_mu);
    int st[4] = {0}; for (int c = 0; c < g_nulc; c++) st[g_ulc[c].state & 3]++;
    uint64_t nc = 0, bc = 0, nb = 0, bb = 0;
    for (uint32_t l = 1; l < g_nul; l++) { if (g_ul[l].buf) { nb++; bb += g_ul[l].len; } else if (g_ul[l].chunk >= 0) { nc++; bc += g_ul[l].len; } }
    pthread_mutex_unlock(&g_ul_mu);
    // 贴图（自有存储的，不含视图；贴图缓冲单计张数）：Metal 已分配里贴图占多少
    uint64_t tn = 0, tb = 0, tbn = 0; for (uint32_t k = 1; k < g_ntex; k++) { gal_tex *t = &g_tex[k]; if (!t->live) continue; if (t->info.target == 9) { tbn++; continue; } if (t->tex && t->tex == t->root) { tn++; tb += t->tex.allocatedSize; } }
    int w = snprintf(o, n, "贴图 %llu 张 %llu MB、贴图缓冲 %llu 张；", (unsigned long long)tn, (unsigned long long)(tb >> 20), (unsigned long long)tbn);
    if (w < 0 || (size_t)w >= n) return;
    o += w; n -= (size_t)w;
    snprintf(o, n, "上传租约 共享块 在切 %d / 退役待 GPU %d / 空闲 %d（各 %u MB）、未交租约 块内 %llu 份 %llu KB / 独立缓冲 %llu 份 %llu MB", st[1], st[2], st[3], UL_CHUNK >> 20,
             (unsigned long long)nc, (unsigned long long)(bc >> 10), (unsigned long long)nb, (unsigned long long)(bb >> 20));
}
// 单测用：out[0] 共享块数（非空）、out[1] 其中空闲、out[2] 在表未交的租约数
void gal_upload_stats(int out[3]) {
    pthread_mutex_lock(&g_ul_mu);
    out[0] = out[1] = out[2] = 0;
    for (int c = 0; c < g_nulc; c++) if (g_ulc[c].state) { out[0]++; out[1] += g_ulc[c].state == 3; }
    for (uint32_t l = 1; l < g_nul; l++) out[2] += g_ul[l].buf != NULL || g_ul[l].chunk >= 0;
    pthread_mutex_unlock(&g_ul_mu);
}
NXGAL_API void nxgal_upload_drop(uint32_t lease) { @autoreleasepool { uint64_t n; uint32_t o; int c; id<MTLBuffer> b = ul_take(lease, &n, &o, &c); (void)b; ul_done_now(c); } }
struct ul_ret { int chunk; int *gpu; };
static void ul_ret_end(struct ul_ret *r) { if (r->chunk >= 0 && !*r->gpu) ul_done_now(r->chunk); }
static void tex_set_data_impl(uint32_t tid, int32_t layer, int32_t level, const nxgal_rect *region, const void *data, uint64_t len, id<MTLBuffer> lease, uint64_t lease_off, int lease_chunk);
NXGAL_API void nxgal_tex_set_data_lease(uint32_t tid, int32_t layer, int32_t level, const nxgal_rect *region, uint32_t lease, uint64_t len) { GAL_API_LOCK(); gal_uw_write(tid); @autoreleasepool {
    uint64_t n = 0; uint32_t off = 0; int c = -1; id<MTLBuffer> b = ul_take(lease, &n, &off, &c);
    if (!b) { GRED_ONCE("贴图写入：上传租约 %u 无效", lease); return; }
    tex_set_data_impl(tid, layer, level, region, (const uint8_t *)b.contents + off, len < n ? len : n, b, off, c);
    ul_trim();
} }
NXGAL_API void nxgal_buf_set_data_lease(uint32_t bid, int32_t offset, uint32_t lease, int32_t size) { @autoreleasepool {
    uint64_t n = 0; uint32_t off = 0; int c = -1; id<MTLBuffer> b = ul_take(lease, &n, &off, &c);
    if (!b) { GRED_ONCE("缓冲写入：上传租约 %u 无效", lease); return; }
    nxgal_buf_set_data(bid, offset, (const uint8_t *)b.contents + off, (uint64_t)size < n ? size : (int32_t)n);   // 从租约拷（同普通写入），拷完即还
    ul_done_now(c);
} }

NXGAL_API void nxgal_tex_set_data(uint32_t tid, int32_t layer, int32_t level, const nxgal_rect *region, const void *data, uint64_t len) { GAL_API_LOCK(); gal_uw_write(tid);
    tex_set_data_impl(tid, layer, level, region, data, len, nil, 0, -1);
}
// lease 非空：data = lease 内容（偏移 lease_off 起），直接拿 lease 当暂存（不再建暂存缓冲、不再拷）；深度模板 / 贴图缓冲仍按 data 走原路。
// lease_chunk ≥ 0：租约在共享块里，用完（GPU 拷完：挂在提交栅栏上的哨兵 / 没录 GPU 命令就当场）给块减一；< 0：独立缓冲，随栅栏放
static void tex_set_data_impl(uint32_t tid, int32_t layer, int32_t level, const nxgal_rect *region, const void *data, uint64_t len, id<MTLBuffer> lease, uint64_t lease_off, int lease_chunk) {
    // 块里的租约：本函数任何返回路径都要给块交还（GPU 用到了就挂哨兵，没用到当场还）
    int ul_gpu = 0;
    struct ul_ret _ulr __attribute__((cleanup(ul_ret_end))) = {lease_chunk, &ul_gpu}; (void)_ulr;
    SW_SCOPE(SW_TEXUP, sw_tex_rw(tid));   // 调度测算：本遍读过 / 正当附件的贴图不能挪到遍外更新（贴图不换块）
    { gal_tex *u = gal_tex_get(tid); int k; gal_cur_enc(&k); g_up_pre = u && u->info.target != 9 && k == 1 && !gal_pass_tex_used(u->root); if (g_up_pre) gal_prepass_want(); }
    struct up_pre_reset { int z; } _upr __attribute__((cleanup(up_pre_end))) = {0}; (void)_upr;
    tex_touch(tid);   // 碰到的贴图有挂起清屏先落实（只落实涉及的，别的继续挂着等下次当附件吃掉）
    GP_SCOPE(GP_UPLOAD);
    gal_tex *t = gal_tex_get(tid); if (!t) { GRED_ONCE("写入：贴图 %u 无效", tid); return; }
    if (t->info.target == 9) { tbuf_io(t, NULL, data, len); return; }
    nxgal_tex_info info = t->info; const nxgal_tex_info *i = &info;
    int n; uint64_t total; sub *s = subs_of(i, layer, level, region, &n, &total);
    if (len < total) { GLOG("【红】写入数据不足：贴图 %u 要 %llu 字节，给 %llu", tid, (unsigned long long)total, (unsigned long long)len); free(s); return; }
    @autoreleasepool {
        if (!g_up_pre) gal_pass_close();   // 挪到遍前段的上传不收本遍（遍前段要不到时 sub_copy 退回在录流，那里照样收遍）
        if (!ds_planes(i)) {
            id<MTLBuffer> b = lease; uint64_t bo = lease ? lease_off : 0;
            if (b && lease_chunk >= 0) { pthread_mutex_lock(&g_ul_mu); int r = g_ulc[lease_chunk].resident; g_ulc[lease_chunk].resident = 1; pthread_mutex_unlock(&g_ul_mu); if (!r) gal_res_add(b); }
            else if (b) gal_res_add(b);
            else { b = staging(total); if (!b) { free(s); return; } memcpy(b.contents, data, total); }
            for (int k = 0; k < n; k++) sub_copy(t, &s[k], b, bo + s[k].off, s[k].stride, s[k].img, MTLBlitOptionNone, 0);
            if (lease_chunk >= 0) { GalUlSentinel *st = [GalUlSentinel new]; st->chunk = lease_chunk; st->generation = g_ul_generation; gal_release_later(st, 0); ul_gpu = 1; }   // 块随 GPU 拷完交还
            else gal_release_later(b, 1);
        } else {
            uint64_t px = 0; for (int k = 0; k < n; k++) px += (uint64_t)s[k].w * s[k].h * s[k].d;
            id<MTLBuffer> b = staging(px * 5); if (!b) { free(s); return; }
            uint64_t p = 0;
            for (int k = 0; k < n; k++) { uint64_t m = (uint64_t)s[k].w * s[k].h;
                ds_to_planes(i->format, (const uint8_t *)data + s[k].off, (float *)b.contents + p, (uint8_t *)b.contents + px * 4 + p, m * s[k].d);
                sub_copy(t, &s[k], b, p * 4, s[k].w * 4, m * 4, MTLBlitOptionDepthFromDepthStencil, 0);
                sub_copy(t, &s[k], b, px * 4 + p, s[k].w, m, MTLBlitOptionStencilFromDepthStencil, 0); p += m * s[k].d; }
            gal_release_later(b, 1);
        }
    }
    free(s);
}

// ---------- 辅助着色器（blit / 多重采样互拷 / 深度模板打包）----------
// blit 照 Vulkan HelperShader：四顶点条带，纹理坐标 = 源矩形 / 源尺寸；目标矩形走视口（翻转时交换纹理坐标）。
// 整数格式按最近读（read），浮点按采样器（线性 / 最近）；深度用 [[depth(any)]] 输出，模板用 [[stencil]] 输出（同 Vulkan DepthBlit / StencilBlit）。
NSString *const k_tex_msl = @
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"struct BV { float4 pos [[position]]; float2 uv; };\n"
"struct BP { float4 region; int4 ip; };\n"
"vertex BV blit_vs(uint vid [[vertex_id]], constant BP &p [[buffer(0)]]) {\n"
"  uint lo = vid & 1u, hi = vid >> 1;\n"
"  BV o; o.pos = float4(float(lo) * 2.0 - 1.0, 1.0 - float(hi) * 2.0, 0.0, 1.0);\n"
"  o.uv = float2(p.region[lo], p.region[2 + hi]); return o; }\n"
"static uint2 texel(float2 uv, uint w, uint h) { return uint2(min(uint(max(uv.x * float(w), 0.0)), w - 1), min(uint(max(uv.y * float(h), 0.0)), h - 1)); }\n"
"fragment float4 fs_f(BV in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) { return t.sample(s, in.uv, level(0)); }\n"
"fragment uint4 fs_u(BV in [[stage_in]], texture2d<uint> t [[texture(0)]]) { return t.read(texel(in.uv, t.get_width(), t.get_height())); }\n"
"fragment int4 fs_i(BV in [[stage_in]], texture2d<int> t [[texture(0)]]) { return t.read(texel(in.uv, t.get_width(), t.get_height())); }\n"
"fragment float4 fs_df(BV in [[stage_in]], depth2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) { return float4(t.sample(s, in.uv, level(0)), 0.0, 0.0, 1.0); }\n"
"struct DO { float d [[depth(any)]]; };\n"
"fragment DO fs_d(BV in [[stage_in]], depth2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) { DO o; o.d = t.sample(s, in.uv, level(0)); return o; }\n"
"fragment DO fs_cd(BV in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) { DO o; o.d = t.sample(s, in.uv, level(0)).r; return o; }\n"
"struct SO { uint s [[stencil]]; };\n"
"fragment SO fs_s(BV in [[stage_in]], texture2d<uint> t [[texture(0)]]) { SO o; o.s = t.read(texel(in.uv, t.get_width(), t.get_height())).r; return o; }\n"
// 非多重采样 → 多重采样（Vulkan ColorDrawToMs）：目标像素 (x,y) 的第 s 个样本 = 源 ((x << sx) | (s & (nx-1)), (y << sy) | (s >> sx))
"fragment uint4 fs_ss2ms(BV in [[stage_in]], uint sid [[sample_id]], texture2d<uint> t [[texture(0)]], constant BP &p [[buffer(0)]]) {\n"
"  uint sx = uint(p.ip.x), sy = uint(p.ip.y); uint2 px = uint2(in.pos.xy);\n"
"  uint2 c = uint2((px.x << sx) | (sid & ((1u << sx) - 1u)), (px.y << sy) | (sid >> sx));\n"
"  return t.read(c); }\n"
// 多重采样 → 非多重采样（Vulkan ColorCopyToNonMs）
"kernel void k_ms2ss(texture2d_ms<uint> src [[texture(0)]], texture2d<uint, access::write> dst [[texture(1)]], constant BP &p [[buffer(0)]], uint2 g [[thread_position_in_grid]]) {\n"
"  if (g.x >= dst.get_width() || g.y >= dst.get_height()) return;\n"
"  uint sx = uint(p.ip.x), sy = uint(p.ip.y);\n"
"  uint s = (g.x & ((1u << sx) - 1u)) | ((g.y & ((1u << sy) - 1u)) << sx);\n"
"  uint2 c = uint2(g.x >> sx, g.y >> sy);\n"
"  if (c.x >= src.get_width() || c.y >= src.get_height()) return;\n"
"  dst.write(src.read(c, s), g); }\n"
// 深度模板两平面 → GAL 布局写进目标缓冲（CopyTo(BufferRange)；Vulkan ConvertD32S8ToD24S8）。fmt：0 D32FloatS8Uint 1 D24UnormS8Uint 2 S8UintD24Unorm 3 X8UintD24Unorm
"struct PK { uint w, h, stride, fmt; };\n"
"kernel void k_dspack(device const float *dep [[buffer(0)]], device const uchar *st [[buffer(1)]], device uchar *dst [[buffer(2)]], constant PK &p [[buffer(3)]], uint2 g [[thread_position_in_grid]]) {\n"
"  if (g.x >= p.w || g.y >= p.h) return;\n"
"  uint i = g.y * p.w + g.x; float d = dep[i]; uint s = st[i];\n"
"  device uchar *o = dst + g.y * p.stride + g.x * (p.fmt == 0 ? 8u : 4u);\n"
"  uint v0, v1 = s;\n"
"  if (p.fmt == 0) v0 = as_type<uint>(d);\n"
"  else { float c = isnan(d) ? 0.0 : clamp(d, 0.0, 1.0); uint d24 = uint(rint(fma(c, 16777216.0, -c)));\n"   // c×(2²⁴−1) 一次舍入
"         v0 = p.fmt == 1 ? ((d24 << 8) | s) : p.fmt == 2 ? ((s << 24) | d24) : (d24 << 8); }\n"
"  for (uint k = 0; k < 4; k++) o[k] = uchar(v0 >> (8 * k));\n"
"  if (p.fmt == 0) for (uint k = 0; k < 4; k++) o[4 + k] = uchar(v1 >> (8 * k)); }\n";
typedef struct { float region[4]; int32_t ip[4]; } blit_params;

static id<MTLLibrary> g_tlib;
static id<MTL4ArgumentTable> g_tvt, g_tft, g_tct;
static id<MTLSamplerState> g_smp_near, g_smp_lin;
static int tl_init(void) {
    if (g_tlib && g_tvt && g_tft && g_tct && g_smp_near && g_smp_lin) return 1;
    NSError *e = nil;
    if (!g_tlib) g_tlib = gal_helper_lib(GH_TEX, &e);
    if (!g_tlib) { GLOG("【红】贴图辅助着色器编译失败：%s", e.localizedDescription.UTF8String); return 0; }
    MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new]; ad.maxBufferBindCount = 4; ad.maxTextureBindCount = 2; ad.maxSamplerStateBindCount = 1;
    g_tvt = [g_gdev newArgumentTableWithDescriptor:ad error:&e]; g_tft = [g_gdev newArgumentTableWithDescriptor:ad error:&e]; g_tct = [g_gdev newArgumentTableWithDescriptor:ad error:&e];
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new]; sd.supportArgumentBuffers = YES;
    sd.sAddressMode = sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
    g_smp_near = [g_gdev newSamplerStateWithDescriptor:sd];
    sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear; g_smp_lin = [g_gdev newSamplerStateWithDescriptor:sd];
    return g_tvt && g_tft && g_tct && g_smp_near && g_smp_lin;
}
static MTL4LibraryFunctionDescriptor *tfn(NSString *name) { MTL4LibraryFunctionDescriptor *f = [MTL4LibraryFunctionDescriptor new]; f.library = g_tlib; f.name = name; return f; }

enum { FS_F, FS_U, FS_I, FS_DF, FS_D, FS_CD, FS_S, FS_SS2MS, FS_N };
static NSString *const k_fs_names[FS_N] = {@"fs_f", @"fs_u", @"fs_i", @"fs_df", @"fs_d", @"fs_cd", @"fs_s", @"fs_ss2ms"};
typedef struct { int fs; MTLPixelFormat cf; NSUInteger samples; id<MTLRenderPipelineState> p; } rp_ent;
static rp_ent *g_rp; static int g_nrp;
// 两级建（同清屏 gal_pass.m clr_base）：输出颜色的片元（fs_f / fs_u / fs_i / fs_df / fs_ss2ms）基础管线 = 片元 + 采样数、颜色附件留空，按目标格式特化；
//   只写深度 / 模板的（fs_d / fs_cd / fs_s）没有颜色附件，整条直接建。单采样常见的几条在 nxgal_warm_internal 预建（gal_warm_tex）
static MTL4RenderPipelineDescriptor *tl_desc(int fs, NSUInteger samples) {
    MTL4RenderPipelineDescriptor *d = [MTL4RenderPipelineDescriptor new];
    d.vertexFunctionDescriptor = tfn(@"blit_vs"); d.fragmentFunctionDescriptor = tfn(k_fs_names[fs]);
    d.rasterSampleCount = samples; d.inputPrimitiveTopology = MTLPrimitiveTopologyClassTriangle;
    return d;
}
static rp_ent *g_rpb; static int g_nrpb;
static id<MTLRenderPipelineState> tl_base(int fs, NSUInteger samples) {
    for (int i = 0; i < g_nrpb; i++) if (g_rpb[i].fs == fs && g_rpb[i].samples == samples) return g_rpb[i].p;
    __auto_type d = tl_desc(fs, samples); gal_pso_unspecialize_color(d, 0);
    NSError *e = nil; id<MTLRenderPipelineState> p = gal_new_render_pso(d, &e);
    if (!p) { GLOG("【红】贴图辅助基础管线 %s 编译失败：%s", k_fs_names[fs].UTF8String, e.localizedDescription.UTF8String); return nil; }
    rp_ent *nt = gal_grow(g_rpb, (size_t)g_nrpb + 1, sizeof *g_rpb, "贴图辅助基础管线表"); if (!nt) return p;   // 审计 P1-67：表扩不动（报红、留原表）就这次不缓存，管线照用
    g_rpb = nt; memset((void *)&g_rpb[g_nrpb], 0, sizeof *g_rpb);
    g_rpb[g_nrpb] = (rp_ent){fs, MTLPixelFormatInvalid, samples, p}; g_nrpb++;
    return p;
}
static id<MTLRenderPipelineState> tl_render(int fs, MTLPixelFormat cf, NSUInteger samples) {
    for (int i = 0; i < g_nrp; i++) if (g_rp[i].fs == fs && g_rp[i].cf == cf && g_rp[i].samples == samples) return g_rp[i].p;
    __auto_type d = tl_desc(fs, samples);
    if (cf != MTLPixelFormatInvalid) d.colorAttachments[0].pixelFormat = cf;
    NSError *e = nil; id<MTLRenderPipelineState> p = nil;
    if (cf != MTLPixelFormatInvalid && gal_pso_can_specialize()) { id<MTLRenderPipelineState> b = tl_base(fs, samples); if (b) p = gal_specialize_render_pso(d, b, &e); }
    if (!p) p = gal_new_render_pso(d, &e);
    if (!p) { GLOG("【红】贴图辅助管线 %s 编译失败：%s", k_fs_names[fs].UTF8String, e.localizedDescription.UTF8String); return nil; }
    rp_ent *nt = gal_grow(g_rp, (size_t)g_nrp + 1, sizeof *g_rp, "贴图辅助管线表"); if (!nt) return p;   // 审计 P1-67：同上
    g_rp = nt; memset((void *)&g_rp[g_nrp], 0, sizeof *g_rp);
    g_rp[g_nrp] = (rp_ent){fs, cf, samples, p}; g_nrp++;
    return p;
}
void gal_warm_tex(void) {
    if (!tl_init()) return;
    if (gal_pso_can_specialize()) { const int cfs[] = {FS_F, FS_U, FS_I, FS_DF}; for (int i = 0; i < 4; i++) tl_base(cfs[i], 1); }
    const int dfs[] = {FS_D, FS_CD, FS_S}; for (int i = 0; i < 3; i++) tl_render(dfs[i], MTLPixelFormatInvalid, 1);
}
static id<MTLComputePipelineState> tl_compute(int which) {   // 0 k_ms2ss 1 k_dspack
    static id<MTLComputePipelineState> c[2];
    if (c[which]) return c[which];
    MTL4ComputePipelineDescriptor *d = [MTL4ComputePipelineDescriptor new];
    d.computeFunctionDescriptor = tfn(which ? @"k_dspack" : @"k_ms2ss");
    NSError *e = nil;
    c[which] = gal_new_compute_pso(d, &e);
    if (!c[which]) GLOG("【红】贴图辅助计算管线编译失败：%s", e.localizedDescription.UTF8String);
    return c[which];
}
static id<MTLDepthStencilState> tl_dss(int depth, int stencil) {
    static id<MTLDepthStencilState> c[2][2];
    if (c[depth][stencil]) return c[depth][stencil];
    MTLDepthStencilDescriptor *d = [MTLDepthStencilDescriptor new];
    d.depthCompareFunction = MTLCompareFunctionAlways; d.depthWriteEnabled = depth != 0;
    if (stencil) { MTLStencilDescriptor *s = [MTLStencilDescriptor new];
        s.stencilCompareFunction = MTLCompareFunctionAlways; s.depthStencilPassOperation = MTLStencilOperationReplace; s.writeMask = 0xff; s.readMask = 0xff;
        d.frontFaceStencil = s; d.backFaceStencil = s; }
    return c[depth][stencil] = [g_gdev newDepthStencilStateWithDescriptor:d];
}

// 目标子资源（相对底层贴图的绝对级 / 层；3D 用 depthPlane）
static void att_set(MTLRenderPassAttachmentDescriptor *a, const gal_tex *t, int level, int slice) {
    a.texture = t->root; a.level = abs_level(t, level);
    if (t->root.textureType == MTLTextureType3D) a.depthPlane = slice; else a.slice = abs_slice(t, slice);
    a.loadAction = MTLLoadActionLoad; a.storeAction = MTLStoreActionStore;
}
// 2D 采样视图（某级某层），pf 指定平面 / 原始格式
static id<MTLTexture> layer_view(const gal_tex *t, MTLPixelFormat pf, int level, int slice) {
    MTLTextureType ty = is_ms(&t->info) ? MTLTextureType2DMultisample : MTLTextureType2D;
    id<MTLTexture> v = root_view(t, pf, ty, level, 1, slice, 1, MTLTextureSwizzleChannelsDefault);
    if (v) gal_release_later(v, 0);
    return v;
}
static MTLPixelFormat stencil_view_fmt(const gal_tex *t) { return t->root.pixelFormat == MTLPixelFormatDepth32Float_Stencil8 ? MTLPixelFormatX32_Stencil8 : t->root.pixelFormat; }

// 一次辅助绘制通道：把 src（某级某层）画到 dst（某级某层）的 vp 矩形。kind：0 颜色 1 深度 / 模板
//   fs_color / fs_depth / fs_stencil = 各附件用的片元函数（-1 = 该平面不画）
static void helper_blit(const gal_tex *src, int s_level, int s_slice, const gal_tex *dst, int d_level, int d_slice,
                        const float region[4], MTLViewport vp, int linear, int fs_color, int fs_depth, int fs_stencil, const int32_t ip[4]) {
    if (gal_m3_unbound(3) || !tl_init()) return;
    if (is_3d(&src->info)) { GRED_ONCE("blit：3D 源贴图未实现"); return; }
    int dw = mipsz(dst->info.width, d_level), dh = mipsz(dst->info.height, d_level);
    MTL4RenderPassDescriptor *pd = gal_be_pass_desc();
    int ds = gal_fmt_is_ds(dst->info.format);
    if (fs_color >= 0) att_set(pd.colorAttachments[0], dst, d_level, d_slice);
    else { if (ds & 1) att_set(pd.depthAttachment, dst, d_level, d_slice); if (ds & 2) att_set(pd.stencilAttachment, dst, d_level, d_slice); }
    pd.renderTargetWidth = dw; pd.renderTargetHeight = dh;
    gal_pass_close();
    // 临时内存取不到（gal_transient 已报红）：本次 blit 跳过，在开通道之前判
    uint64_t gpu; blit_params *bp = gal_transient(sizeof *bp, 16, &gpu); if (!bp) return;
    id<MTL4RenderCommandEncoder> e = gal_render_begin_desc(pd);
    memcpy(bp->region, region, sizeof bp->region); for (int k = 0; k < 4; k++) bp->ip[k] = ip ? ip[k] : 0;
    [g_tvt setAddress:gpu atIndex:0]; [g_tft setAddress:gpu atIndex:0];
    [g_tft setSamplerState:(linear ? g_smp_lin : g_smp_near).gpuResourceID atIndex:0];
    [e setArgumentTable:g_tvt atStages:MTLRenderStageVertex];
    [e setViewport:vp]; [e setScissorRect:(MTLScissorRect){0, 0, (NSUInteger)dw, (NSUInteger)dh}];
    [e setCullMode:MTLCullModeNone]; [e setTriangleFillMode:MTLTriangleFillModeFill]; [e setDepthBias:0 slopeScale:0 clamp:0];
    NSUInteger samples = imax(1, dst->info.samples);
    int fss[3] = {fs_color, fs_depth, fs_stencil};
    for (int k = 0; k < 3; k++) {
        if (fss[k] < 0) continue;
        int fs = fss[k];
        MTLPixelFormat spf = fs == FS_S ? stencil_view_fmt(src) : fs == FS_SS2MS ? gal_raw_uint_fmt(src->info.bpp) : src->tex.pixelFormat;
        id<MTLTexture> sv = layer_view(src, spf, s_level, s_slice);
        MTLPixelFormat cf = k == 0 ? (fs == FS_SS2MS ? gal_raw_uint_fmt(dst->info.bpp) : dst->tex.pixelFormat) : MTLPixelFormatInvalid;
        id<MTLRenderPipelineState> p = tl_render(fs, cf, samples);
        if (!sv || !p) continue;
        [g_tft setTexture:sv.gpuResourceID atIndex:0];
        [e setArgumentTable:g_tft atStages:MTLRenderStageFragment];
        [e setRenderPipelineState:p];
        [e setDepthStencilState:tl_dss(k == 1, k == 2)];
        [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    }
    gal_enc_end();
    g_genc_serial++;
}

// ---------- 拷贝 ----------
// 原始字节拷贝（经暂存缓冲）：每行按字节对拷，行数 / 行字节取两边最小。用于每像素字节不同（Vulkan CopyIncompatibleFormats：加宽 / 缩窄 = 行内逐字节重解释）
// 与压缩 ↔ 非压缩（Vulkan 用块兼容视图；Metal 不能在两者间建视图，经缓冲中转）。slice 对 3D 是 z。
static void raw_copy(const gal_tex *s, int sl, int ss, const gal_tex *d, int dl, int dsl) {
    const nxgal_tex_info *si = &s->info, *di = &d->info;
    int ws = mipsz(si->width, sl), hs = mipsz(si->height, sl), wd = mipsz(di->width, dl), hd = mipsz(di->height, dl);
    int bws = imax(1, si->block_w), bhs = imax(1, si->block_h), bwd = imax(1, di->block_w), bhd = imax(1, di->block_h);
    uint64_t rbs = (uint64_t)((ws + bws - 1) / bws) * si->bpp, rbd = (uint64_t)((wd + bwd - 1) / bwd) * di->bpp;
    int rows = imin((hs + bhs - 1) / bhs, (hd + bhd - 1) / bhd);
    uint64_t rb = rbs < rbd ? rbs : rbd;
    int dblocks = (int)(rb / di->bpp); if (!dblocks || !rows) return;
    uint64_t stride = (rbs + 15) & ~15ull;
    id<MTLBuffer> b = gal_newbuf_test_fail ? nil : [g_gdev newBufferWithLength:stride * rows options:MTLResourceStorageModePrivate];
    if (!b) { GLOG("【红】贴图原始拷贝：建 %llu 字节中转缓冲失败（本次拷贝跳过）：%s", (unsigned long long)(stride * rows), gal_mem_note()); return; }
    gal_res_add(b);
    int s3 = s->root.textureType == MTLTextureType3D, d3 = d->root.textureType == MTLTextureType3D;
    [gal_blit_enc() copyFromTexture:s->root sourceSlice:s3 ? 0 : abs_slice(s, ss) sourceLevel:abs_level(s, sl) sourceOrigin:MTLOriginMake(0, 0, s3 ? ss : 0)
                         sourceSize:MTLSizeMake(ws, imin(hs, rows * bhs), 1) toBuffer:b destinationOffset:0 destinationBytesPerRow:stride destinationBytesPerImage:stride * rows];
    [gal_blit_enc() copyFromBuffer:b sourceOffset:0 sourceBytesPerRow:stride sourceBytesPerImage:stride * rows
                        sourceSize:MTLSizeMake(imin(wd, dblocks * bwd), imin(hd, rows * bhd), 1) toTexture:d->root
                  destinationSlice:d3 ? 0 : abs_slice(d, dsl) destinationLevel:abs_level(d, dl) destinationOrigin:MTLOriginMake(0, 0, d3 ? dsl : 0)];
    gal_release_later(b, 1);
}
// 同格式（或同大小可建视图的格式）的一个子资源直接拷：深度模板两平面一起
// 遍内贴图拷贝挪到遍前段（帧级调度，帧率能耗线 10-23，NXGAL_TEXCOPY_PRE=1，缺省关）：渲染遍开着、源和目标本遍都没用过（没当附件 / 没采样 / 没当图像）时，
// 这次直接拷贝录进遍前段（排在本遍之前、更早各遍之后），本遍不切。正确性：本遍前半段不碰这两张，看不出拷贝提前；后半段照样看到拷贝结果。
// 只管直接拷贝（Metal copyFromTexture）；要画过去的格式转换、多重采样互转照旧切遍。Mac 切遍统计：马车8 每帧 9 次「贴图拷贝·可重排」、附件读写 20.9 MB
static int g_cp_pre;
static int texcopy_pre_on(void) { static int v = -1; if (v < 0) { const char *e = getenv("NXGAL_TEXCOPY_PRE"); v = e && *e == '1'; } return v; }
// 没挪的原因（累计，NXGAL_TRACE_ENC 打印）：[0] 没开渲染遍 [1] 源本遍写过 [2] 目标本遍用过 [3] 条件满足但走的不是直接拷贝（缩放 / 解析 / 格式转换要画） [4] 遍前段没开
uint64_t g_cp_why[5];
static int g_cp_hit;
static void cp_pre_arm(const gal_tex *s, const gal_tex *d) {
    if (!texcopy_pre_on() || !s || !d) { g_cp_pre = 0; return; }
    int k; gal_cur_enc(&k);
    // 源本遍只被采样也能挪：拷贝挪前后读到的都是开遍前的内容
    int sw = k == 1 && gal_pass_tex_written(s->root), du = k == 1 && gal_pass_tex_used(d->root);
    g_cp_pre = k == 1 && !sw && !du; g_cp_hit = 0;
    if (k != 1) g_cp_why[0]++; else if (sw) g_cp_why[1]++; else if (du) g_cp_why[2]++;
    if (g_cp_pre) gal_prepass_want();
}
static void cp_pre_end(void *p) { (void)p; if (g_cp_pre && !g_cp_hit) g_cp_why[3]++; g_cp_pre = 0; }
uint64_t g_texcp_n[2];   // 贴图直接拷贝次数：[0] 在录流 [1] 遍前段
static void direct_copy(const gal_tex *s, int sl, int ss, const gal_tex *d, int dl, int dsl, int x, int y, int dx, int dy, int w, int h) {
    id<MTLTexture> st = s->root;
    int s3 = st.textureType == MTLTextureType3D, d3 = d->root.textureType == MTLTextureType3D;
    if (st.pixelFormat != d->root.pixelFormat) {   // Metal 拷贝要求两边同像素格式：源按目标格式建视图（同大小格式，Vulkan 里是兼容格式的 CmdCopyImage）
        st = [s->root newTextureViewWithPixelFormat:d->root.pixelFormat];
        if (!st) { GLOG("【红】拷贝：源格式 %lu 不能按目标格式 %lu 建视图", (unsigned long)s->root.pixelFormat, (unsigned long)d->root.pixelFormat); return; }
        gal_release_later(st, 0);
    }
    // 区域按两边 Metal 底层贴图在该级的真实尺寸夹住：越界的拷贝 Metal 不定义（校验层断言，无校验层时 GPU 越界写）。
    // 10-21 暗黑2 Mac 开校验层：宽屏放宽贴图 1564 宽第 3 级 195、拷贝按 196 宽录 → 断言退出。越界说明上游尺寸算错，照报红（前 8 次带尺寸）
    int sw = imax(1, (int)(s->root.width >> abs_level(s, sl))), sh = imax(1, (int)(s->root.height >> abs_level(s, sl)));
    int dw = imax(1, (int)(d->root.width >> abs_level(d, dl))), dh = imax(1, (int)(d->root.height >> abs_level(d, dl)));
    int cw = imin(w, imin(sw - x, dw - dx)), ch = imin(h, imin(sh - y, dh - dy));
    if (cw != w || ch != h) {
        static int nclip; if (nclip++ < 8) GLOG("【红】贴图拷贝越界、已夹到贴图内（第 %d 次）：区域 %dx%d 源起点 (%d,%d) 源该级 %dx%d → 目标起点 (%d,%d) 目标该级 %dx%d，实拷 %dx%d",
                                               nclip, w, h, x, y, sw, sh, dx, dy, dw, dh, cw, ch);
        if (cw <= 0 || ch <= 0) return;
        w = cw; h = ch;
    }
    id e = g_cp_pre ? gal_prepass_enc() : nil;
    if (texcopy_pre_on()) { g_texcp_n[e != nil]++; if (g_cp_pre) { g_cp_hit = 1; if (!e) g_cp_why[4]++; } }
    if (!e) e = gal_blit_enc();
    [e copyFromTexture:st sourceSlice:s3 ? 0 : abs_slice(s, ss) sourceLevel:abs_level(s, sl) sourceOrigin:MTLOriginMake(x, y, s3 ? ss : 0) sourceSize:MTLSizeMake(w, h, 1)
                          toTexture:d->root destinationSlice:d3 ? 0 : abs_slice(d, dsl) destinationLevel:abs_level(d, dl) destinationOrigin:MTLOriginMake(dx, dy, d3 ? dsl : 0)];
}
// 多重采样 → 非多重采样（每层；只有颜色）
static void ms_to_ss(const gal_tex *s, int ss, const gal_tex *d, int dl, int dsl) {
    if (!tl_init()) return;
    MTLPixelFormat raw = gal_raw_uint_fmt(s->info.bpp);
    if (raw == MTLPixelFormatInvalid || d->info.bpp != s->info.bpp) { GRED_ONCE("多重采样 → 非多重采样：每像素字节 %d → %d 未实现", s->info.bpp, d->info.bpp); return; }
    id<MTLTexture> sv = layer_view(s, raw, 0, ss), dv = root_view(d, raw, MTLTextureType2D, dl, 1, dsl, 1, MTLTextureSwizzleChannelsDefault);
    if (!sv || !dv) { GLOG("【红】多重采样 → 非多重采样：建视图失败"); return; }
    gal_release_later(dv, 0);
    id<MTLComputePipelineState> p = tl_compute(0); if (!p) return;
    int lg = s->info.samples == 2 ? 1 : s->info.samples == 4 ? 2 : s->info.samples == 8 ? 3 : s->info.samples == 16 ? 4 : 0;
    uint64_t gpu; blit_params *bp = gal_transient(sizeof *bp, 16, &gpu); if (!bp) return;
    memset(bp, 0, sizeof *bp);
    bp->ip[0] = (lg + 1) / 2; bp->ip[1] = lg / 2;   // 2→2×1 4→2×2 8→4×2 16→4×4（Vulkan GetSampleCountXYLog2）
    id<MTL4ComputeCommandEncoder> e = gal_cmp_enc(); if (!e) return;
    [g_tct setTexture:sv.gpuResourceID atIndex:0]; [g_tct setTexture:dv.gpuResourceID atIndex:1]; [g_tct setAddress:gpu atIndex:0];
    [e setArgumentTable:g_tct]; [e setComputePipelineState:p];
    [e dispatchThreads:MTLSizeMake(dv.width, dv.height, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
}
static void ss_to_ms(const gal_tex *s, int sl, int ss, const gal_tex *d, int dsl) {
    if (d->info.bpp != s->info.bpp || gal_raw_uint_fmt(s->info.bpp) == MTLPixelFormatInvalid) { GRED_ONCE("非多重采样 → 多重采样：每像素字节 %d → %d 未实现", s->info.bpp, d->info.bpp); return; }
    int lg = d->info.samples == 2 ? 1 : d->info.samples == 4 ? 2 : d->info.samples == 8 ? 3 : d->info.samples == 16 ? 4 : 0;
    int32_t ip[4] = {(lg + 1) / 2, lg / 2, 0, 0};
    float region[4] = {0, 1, 0, 1};
    int w = d->info.width, h = d->info.height;
    // 渲染到目标的原始整数视图：helper_blit 的颜色附件用 dst->tex 的格式，这里临时构造一个以原始格式视图为底的 gal_tex
    id<MTLTexture> dv = root_view(d, gal_raw_uint_fmt(d->info.bpp), is_ms(&d->info) && d->info.target == 6 ? MTLTextureType2DMultisampleArray : MTLTextureType2DMultisample,
                                  0, 1, 0, view_slices(&d->info), MTLTextureSwizzleChannelsDefault);
    if (!dv) { GLOG("【红】非多重采样 → 多重采样：建目标视图失败"); return; }
    gal_release_later(dv, 0);
    gal_tex dt = *d; dt.root = dv; dt.tex = dv; dt.base_layer = 0; dt.base_level = 0;
    helper_blit(s, sl, ss, &dt, 0, dsl, region, (MTLViewport){0, 0, w, h, 0, 1}, 0, FS_SS2MS, -1, -1, ip);
}

// 通用拷贝（照 Vulkan TextureView.CopyTo 两种重载的分支顺序）：layers = 层（3D 为 z）数，levels = 级数
static void copy_core(const gal_tex *s, const gal_tex *d, int s_layer, int d_layer, int s_level, int d_level, int layers, int levels) {
    const nxgal_tex_info *si = &s->info, *di = &d->info;
    int sds = gal_fmt_is_ds(si->format), dds = gal_fmt_is_ds(di->format);
    if (is_ms(si) && !is_ms(di)) {
        if (sds) { GRED_ONCE("深度模板 多重采样 → 非多重采样 未实现"); return; }
        for (int z = 0; z < layers; z++) ms_to_ss(s, s_layer + z, d, d_level, d_layer + z);
        return;
    }
    if (!is_ms(si) && is_ms(di)) {
        if (sds) { GRED_ONCE("深度模板 非多重采样 → 多重采样 未实现"); return; }
        for (int z = 0; z < layers; z++) ss_to_ms(s, s_level, s_layer + z, d, d_layer + z);
        return;
    }
    int same_ds = sds && dds && s->root.pixelFormat == d->root.pixelFormat;   // D24S8 三种与 D32FloatS8Uint 在 Metal 是同一格式：直接拷
    for (int l = 0; l < levels; l++) {
        int sl = s_level + l, dl = d_level + l;
        if (sl >= imax(1, si->levels) || dl >= imax(1, di->levels)) break;
        int ns = (is_3d(si) ? mipsz(si->depth, sl) : tex_layers(si)) - s_layer, nd = (is_3d(di) ? mipsz(di->depth, dl) : tex_layers(di)) - d_layer;
        int n = imin(layers, imin(ns, nd));
        int ws = mipsz(si->width, sl), hs = mipsz(si->height, sl), wd = mipsz(di->width, dl), hd = mipsz(di->height, dl);
        for (int z = 0; z < n; z++) {
            int a = s_layer + z, b = d_layer + z;
            if (!same_ds && si->bpp != di->bpp) {
                if (sds || dds) { GRED_ONCE("深度模板与每像素字节不同的格式互拷未实现：%d → %d", si->format, di->format); return; }
                raw_copy(s, sl, a, d, dl, b);
            } else if (!same_ds && !!sds != !!dds) {   // 深度 ↔ 颜色：Vulkan CopyColor = 按值画过去（最近采样）
                int w = imin(ws, wd), h = imin(hs, hd);
                float region[4] = {0, (float)w / ws, 0, (float)h / hs};
                int fsc = -1, fsd = -1;
                if (dds) fsd = FS_CD; else fsc = FS_DF;
                helper_blit(s, sl, a, d, dl, b, region, (MTLViewport){0, 0, w, h, 0, 1}, 0, fsc, fsd, -1, NULL);
            } else if (is_compressed(si) != is_compressed(di) || (is_compressed(si) && (si->block_w != di->block_w || si->block_h != di->block_h))) {
                raw_copy(s, sl, a, d, dl, b);
            } else {
                direct_copy(s, sl, a, d, dl, b, 0, 0, 0, 0, imin(ws, wd), imin(hs, hd));
            }
        }
    }
}

NXGAL_API void nxgal_tex_copy(uint32_t src, uint32_t dst, int32_t first_layer, int32_t first_level) { GAL_API_LOCK(); gal_uw_write(dst);
    SW_SCOPE(SW_TEXCOPY, sw_tex_wr(src) || sw_tex_rw(dst));   // 调度测算：源是本遍画的、或目标本遍用过，才是真依赖
    tex_touch(src); tex_touch(dst);   // 碰到的贴图有挂起清屏先落实（只落实涉及的，别的继续挂着等下次当附件吃掉）
    GP_SCOPE(GP_COPY);
    gal_tex *s = gal_tex_get(src), *d = gal_tex_get(dst); if (!s || !d) { GRED_ONCE("拷贝：贴图 %u / %u 无效", src, dst); return; }
    if (s->info.target == 9 || d->info.target == 9) { GRED_ONCE("贴图缓冲参与贴图拷贝未实现"); return; }
    cp_pre_arm(s, d); struct { int z; } _cpr __attribute__((cleanup(cp_pre_end))) = {0}; (void)_cpr;
    @autoreleasepool { gal_tex sc = *s, dc = *d; copy_core(&sc, &dc, 0, first_layer, 0, first_level, depth_or_layers(&s->info), imax(1, s->info.levels)); }
}
NXGAL_API void nxgal_tex_copy_slice(uint32_t src, uint32_t dst, int32_t src_layer, int32_t dst_layer, int32_t src_level, int32_t dst_level) { GAL_API_LOCK(); gal_uw_write(dst);
    SW_SCOPE(SW_TEXCOPY, sw_tex_wr(src) || sw_tex_rw(dst));
    tex_touch(src); tex_touch(dst);   // 碰到的贴图有挂起清屏先落实（只落实涉及的，别的继续挂着等下次当附件吃掉）
    GP_SCOPE(GP_COPY);
    gal_tex *s = gal_tex_get(src), *d = gal_tex_get(dst); if (!s || !d) { GRED_ONCE("拷贝：贴图 %u / %u 无效", src, dst); return; }
    if (s->info.target == 9 || d->info.target == 9) { GRED_ONCE("贴图缓冲参与贴图拷贝未实现"); return; }
    cp_pre_arm(s, d); struct { int z; } _cpr __attribute__((cleanup(cp_pre_end))) = {0}; (void)_cpr;
    @autoreleasepool { gal_tex sc = *s, dc = *d; copy_core(&sc, &dc, src_layer, dst_layer, src_level, dst_level, 1, 1); }
}

// 多重采样解析（Vulkan：同尺寸整张 CopyTo(Extents2D) 且采样数不同 → CmdResolveImage）：空通道 + 存储动作 MultisampleResolve
static void resolve_layer(const gal_tex *s, int ss, const gal_tex *d, int dl, int dsl) {
    MTL4RenderPassDescriptor *pd = gal_be_pass_desc();
    int ds = gal_fmt_is_ds(s->info.format);
    MTLRenderPassAttachmentDescriptor *as[2] = {nil, nil};
    if (!ds) as[0] = pd.colorAttachments[0];
    else { if (ds & 1) as[0] = pd.depthAttachment; if (ds & 2) as[1] = pd.stencilAttachment; }
    for (int k = 0; k < 2; k++) { MTLRenderPassAttachmentDescriptor *a = as[k]; if (!a) continue;
        att_set(a, s, 0, ss); a.storeAction = MTLStoreActionMultisampleResolve;
        a.resolveTexture = d->root; a.resolveLevel = abs_level(d, dl);
        if (d->root.textureType == MTLTextureType3D) a.resolveDepthPlane = dsl; else a.resolveSlice = abs_slice(d, dsl); }
    pd.renderTargetWidth = s->info.width; pd.renderTargetHeight = s->info.height;
    gal_pass_close(); gal_render_begin_desc(pd); gal_enc_end(); g_genc_serial++;
}

NXGAL_API void nxgal_tex_copy_region(uint32_t src, uint32_t dst, const nxgal_rect *sr, const nxgal_rect *dr, int32_t linear) { GAL_API_LOCK(); gal_uw_write(dst);
    SW_SCOPE(SW_TEXCOPY, sw_tex_wr(src) || sw_tex_rw(dst));
    tex_touch(src); tex_touch(dst);   // 碰到的贴图有挂起清屏先落实（只落实涉及的，别的继续挂着等下次当附件吃掉）
    GP_SCOPE(GP_COPY);
    gal_tex *sp = gal_tex_get(src), *dp = gal_tex_get(dst); if (!sp || !dp) { GRED_ONCE("blit：贴图 %u / %u 无效", src, dst); return; }
    if (sp->info.target == 9 || dp->info.target == 9) { GRED_ONCE("贴图缓冲参与 blit 未实现"); return; }
    gal_tex sc = *sp, dc = *dp; const gal_tex *s = &sc, *d = &dc;
    const nxgal_tex_info *si = &s->info, *di = &d->info;
    int sx1 = sr->x, sy1 = sr->y, sx2 = sr->x + sr->w, sy2 = sr->y + sr->h;
    int dx1 = dr->x, dy1 = dr->y, dx2 = dr->x + dr->w, dy2 = dr->y + dr->h;
    int layers = imin(depth_or_layers(si), depth_or_layers(di)), levels = imin(imax(1, si->levels), imax(1, di->levels));
    int same_pf = s->tex.pixelFormat == d->tex.pixelFormat;
    cp_pre_arm(s, d); struct { int z; } _cpr __attribute__((cleanup(cp_pre_end))) = {0}; (void)_cpr;   // 只影响下面走直接拷贝的分支
    @autoreleasepool {
        // ① 整张同尺寸同格式：直接拷（采样数不同 → 解析）
        if (same_pf && sx1 == 0 && sy1 == 0 && dx1 == 0 && dy1 == 0 && sx2 == si->width && sy2 == si->height && dx2 == di->width && dy2 == di->height && si->width == di->width && si->height == di->height) {
            if (imax(1, si->samples) > 1 && si->samples != di->samples) { for (int z = 0; z < layers; z++) resolve_layer(s, z, d, 0, z); }
            else copy_core(s, d, 0, 0, 0, 0, layers, levels);
            return;
        }
        // ② 同格式同采样数、不缩放不翻转：逐级逐层区域直拷（等价 vkCmdBlitImage 1:1，深度 / 整数格式也精确）
        int ds = gal_fmt_is_ds(di->format);
        if (same_pf && imax(1, si->samples) == imax(1, di->samples) && sr->w == dr->w && sr->h == dr->h && sr->w > 0 && sr->h > 0) {
            for (int l = 0; l < levels; l++) {
                int sw = mipsz(si->width, l), sh = mipsz(si->height, l), dw = mipsz(di->width, l), dh = mipsz(di->height, l);
                int x = imin(sx1 >> l, sw), y = imin(sy1 >> l, sh), X = imin(dx1 >> l, dw), Y = imin(dy1 >> l, dh);
                int w = imin(imin((sx2 >> l), sw) - x, imin((dx2 >> l), dw) - X), h = imin(imin((sy2 >> l), sh) - y, imin((dy2 >> l), dh) - Y);
                if (w <= 0 || h <= 0) continue;
                int n = is_3d(si) || is_3d(di) ? imax(1, layers >> l) : layers;
                for (int z = 0; z < n; z++) direct_copy(s, l, z, d, l, z, x, y, X, Y, w, h);
            }
            return;
        }
        if (is_compressed(si) || is_compressed(di)) { GRED_ONCE("压缩格式缩放 blit 未实现（格式 %d → %d）", si->format, di->format); return; }
        if (is_ms(si) || is_ms(di)) { GRED_ONCE("多重采样缩放 blit 未实现"); return; }
        // ③ 画过去（Vulkan HelperShader.Blit：逐级逐层，矩形按级右移）
        int sct = gal_fmt_ctype(si->format), dct = gal_fmt_ctype(di->format), sds = gal_fmt_is_ds(si->format);
        int fsc = -1, fsd = -1, fss = -1;
        if (ds) { if (!sds) fsd = FS_CD; else { if ((ds & 1) && (sds & 1)) fsd = FS_D; if ((ds & 2) && (sds & 2)) fss = FS_S; } }
        else if (sds) fsc = FS_DF;
        else if (sct != dct) { GRED_ONCE("blit：分量类型不同（%d → %d）未实现", si->format, di->format); return; }
        else fsc = dct == 1 ? FS_U : dct == 2 ? FS_I : FS_F;
        int lin = linear && !ds && dct == 0 && !sds;
        for (int l = 0; l < levels; l++) {
            int sw = mipsz(si->width, l), sh = mipsz(si->height, l);
            int a1 = dx1 >> l, a2 = dx2 >> l, b1 = dy1 >> l, b2 = dy2 >> l;
            float region[4] = {(float)(sx1 >> l) / sw, (float)(sx2 >> l) / sw, (float)(sy1 >> l) / sh, (float)(sy2 >> l) / sh};
            if (a1 > a2) { float t = region[0]; region[0] = region[1]; region[1] = t; }
            if (b1 > b2) { float t = region[2]; region[2] = region[3]; region[3] = t; }
            MTLViewport vp = {imin(a1, a2), imin(b1, b2), abs(a2 - a1), abs(b2 - b1), 0, 1};
            if (vp.width <= 0 || vp.height <= 0) continue;
            for (int z = 0; z < layers; z++) helper_blit(s, l, z, d, l, z, region, vp, lin, fsc, fsd, fss, NULL);
        }
    }
}

// CopyTo(BufferRange, layer, level, stride)：一层一级拷进缓冲（行跨度 stride，0 = GAL 默认跨度）；深度模板两平面经计算着色器打包成 GAL 布局
NXGAL_API void nxgal_tex_copy_to_buffer(uint32_t src, const nxgal_buf_range *dst, int32_t layer, int32_t level, int32_t stride) { GAL_API_LOCK();
    SW_SCOPE(SW_TEXCOPY, sw_tex_wr(src));   // 目标缓冲换新块
    tex_touch(src);   // 碰到的贴图有挂起清屏先落实（只落实涉及的，别的继续挂着等下次当附件吃掉）
    gal_tex *sp = gal_tex_get(src); if (!sp) { GRED_ONCE("拷进缓冲：贴图 %u 无效", src); return; }
    if (sp->info.target == 9) { GRED_ONCE("贴图缓冲 CopyTo(BufferRange) 未实现"); return; }
    gal_tex sc = *sp; const gal_tex *s = &sc; const nxgal_tex_info *i = &s->info;
    uint64_t moff; id<MTLBuffer> b = gal_buf_mtl(dst->buf, dst->offset, &moff); if (!b) { GRED_ONCE("拷进缓冲：缓冲 %u 无效", dst->buf); return; }
    lvl_geo g = geo(i, level);
    uint64_t rs = stride > 0 ? (uint64_t)stride : g.stride;
    int bh = imax(1, i->block_h), rows = (g.h + bh - 1) / bh;
    sub sb = {level, is_3d(i) ? 0 : layer, 0, 0, is_3d(i) ? layer : 0, g.w, g.h, 1, 0, rs, rs * rows};
    // 写入量超出目标区间就整次跳过并报红：不让 GPU 写出缓冲区间（越过缓冲尾 = 缺页 / 踩别的数据）。
    // 10-21 巫师3 Mac 开校验层：宽屏放宽贴图 1564×180 拷进按客体 1280 宽算的 983040 字节区间，要写 1126080 → 断言退出；真机无校验层即越界写
    uint64_t need = ds_planes(i) ? rs * (rows - 1) + (uint64_t)g.w * i->bpp : rs * (rows - 1) + g.stride;
    if (dst->size > 0 && need > (uint64_t)dst->size) {
        static int nover; if (nover++ < 8) GLOG("【红】拷进缓冲越界、本次跳过（第 %d 次）：贴图 %dx%d 级 %d 格式 %d 行跨度 %llu × %d 行要写 %llu 字节，目标区间只有 %d 字节",
                                               nover, g.w, g.h, level, i->format, (unsigned long long)rs, rows, (unsigned long long)need, dst->size);
        return;
    }
    @autoreleasepool {
        if (!ds_planes(i)) {
            if (moff % (uint64_t)i->bpp || rs % (uint64_t)i->bpp) {   // Metal 要求偏移 / 行跨度是像素字节的倍数：经暂存中转
                id<MTLBuffer> t = staging(rs * rows); if (!t) return;
                sub_copy(s, &sb, t, 0, rs, rs * rows, MTLBlitOptionNone, 1);
                [gal_blit_enc() copyFromBuffer:t sourceOffset:0 toBuffer:b destinationOffset:moff size:rs * (rows - 1) + g.stride];
                gal_release_later(t, 1);
            } else sub_copy(s, &sb, b, moff, rs, rs * rows, MTLBlitOptionNone, 1);
            return;
        }
        if (!tl_init()) return;
        uint64_t m = (uint64_t)g.w * g.h;
        id<MTLBuffer> t = gal_newbuf_test_fail ? nil : [g_gdev newBufferWithLength:m * 5 options:MTLResourceStorageModePrivate];
        if (!t) { GLOG("【红】深度模板拷进缓冲：建 %llu 字节中转缓冲失败（本次拷贝跳过）：%s", (unsigned long long)(m * 5), gal_mem_note()); return; }
        gal_res_add(t);
        sub_copy(s, &sb, t, 0, g.w * 4, m * 4, MTLBlitOptionDepthFromDepthStencil, 1);
        sub_copy(s, &sb, t, m * 4, g.w, m, MTLBlitOptionStencilFromDepthStencil, 1);
        id<MTLComputePipelineState> p = tl_compute(1); if (!p) return;
        uint64_t gpu; uint32_t *pk = gal_transient(16, 16, &gpu);
        if (!pk) { gal_release_later(t, 1); return; }
        pk[0] = g.w; pk[1] = g.h; pk[2] = (uint32_t)rs;
        pk[3] = i->format == F_D32FloatS8Uint ? 0 : i->format == F_D24UnormS8Uint ? 1 : i->format == F_S8UintD24Unorm ? 2 : 3;
        id<MTL4ComputeCommandEncoder> e = gal_cmp_enc(); if (!e) { gal_release_later(t, 1); return; }
        [g_tct setAddress:t.gpuAddress atIndex:0]; [g_tct setAddress:t.gpuAddress + m * 4 atIndex:1];
        [g_tct setAddress:b.gpuAddress + moff atIndex:2]; [g_tct setAddress:gpu atIndex:3];
        [e setArgumentTable:g_tct]; [e setComputePipelineState:p];
        [e dispatchThreads:MTLSizeMake(g.w, g.h, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
        gal_release_later(t, 1);
    }
}

static int tbuf_elem_size(MTLPixelFormat pf) {
    switch (pf) {
        case MTLPixelFormatR8Unorm: case MTLPixelFormatR8Snorm: case MTLPixelFormatR8Uint: case MTLPixelFormatR8Sint: return 1;
        case MTLPixelFormatR16Float: case MTLPixelFormatR16Unorm: case MTLPixelFormatR16Snorm: case MTLPixelFormatR16Uint: case MTLPixelFormatR16Sint:
        case MTLPixelFormatRG8Unorm: case MTLPixelFormatRG8Snorm: case MTLPixelFormatRG8Uint: case MTLPixelFormatRG8Sint:
        case MTLPixelFormatB5G6R5Unorm: case MTLPixelFormatA1BGR5Unorm: case MTLPixelFormatABGR4Unorm: case MTLPixelFormatBGR5A1Unorm: return 2;
        case MTLPixelFormatR32Float: case MTLPixelFormatR32Uint: case MTLPixelFormatR32Sint:
        case MTLPixelFormatRG16Float: case MTLPixelFormatRG16Unorm: case MTLPixelFormatRG16Snorm: case MTLPixelFormatRG16Uint: case MTLPixelFormatRG16Sint:
        case MTLPixelFormatRGBA8Unorm: case MTLPixelFormatRGBA8Unorm_sRGB: case MTLPixelFormatRGBA8Snorm: case MTLPixelFormatRGBA8Uint: case MTLPixelFormatRGBA8Sint:
        case MTLPixelFormatBGRA8Unorm: case MTLPixelFormatBGRA8Unorm_sRGB:
        case MTLPixelFormatRGB10A2Unorm: case MTLPixelFormatRGB10A2Uint: case MTLPixelFormatRG11B10Float: case MTLPixelFormatRGB9E5Float: return 4;
        case MTLPixelFormatRG32Float: case MTLPixelFormatRG32Uint: case MTLPixelFormatRG32Sint:
        case MTLPixelFormatRGBA16Float: case MTLPixelFormatRGBA16Unorm: case MTLPixelFormatRGBA16Snorm: case MTLPixelFormatRGBA16Uint: case MTLPixelFormatRGBA16Sint: return 8;
        case MTLPixelFormatRGBA32Float: case MTLPixelFormatRGBA32Uint: case MTLPixelFormatRGBA32Sint: return 16;
        default: return 0;
    }
}
// SetStorage：Target.TextureBuffer 的 Metal 贴图直接由缓冲建（newTextureWithDescriptor:offset:bytesPerRow:，共用内存）。
//   对齐：偏移须是 minimumTextureBufferAlignmentForPixelFormat 的倍数（本机实测 16 = Capabilities.textureBufferOffsetAlignment）；不齐报红不挂。
//   可见性：贴图与缓冲是同一段内存——GPU 写（拷贝 / 着色器）经编码器之间 / 编码器内屏障可见；CPU 写（共享 / 零拷贝缓冲）下次提交起可见。不需要额外刷新。
//   同一区间重复 SetStorage 不重建（同 Vulkan TextureBuffer.SetStorage）；换区间 → 重建并 gen++（绑定处据此重写参数缓冲）。
NXGAL_API void nxgal_tex_set_storage(uint32_t tid, const nxgal_buf_range *r) { GAL_API_LOCK(); gal_uw_write(tid);
    gal_pass_rt_dirty();
    tex_touch(tid);   // 碰到的贴图有挂起清屏先落实（只落实涉及的，别的继续挂着等下次当附件吃掉）
    g_obj_gen++;   // 同号换对象：按集复用的参数缓冲作废
    gal_tex *t = gal_tex_get(tid); if (!t) { GRED_ONCE("SetStorage：贴图 %u 无效", tid); return; }
    if (t->info.target != 9) { GRED_ONCE("SetStorage：贴图 %u 不是贴图缓冲（目标 %d）", tid, t->info.target); return; }
    if (t->tex && t->storage.buf == r->buf && t->storage.offset == r->offset && t->storage.size == r->size) return;
    uint64_t moff; id<MTLBuffer> b = gal_buf_mtl(r->buf, r->offset, &moff);
    if (!b) { GRED_ONCE("SetStorage：缓冲 %u 无效", r->buf); return; }
    MTLPixelFormat pf = gal_fmt_mtl(t->info.format);
    // 每元素字节数按 Metal 格式定（贴图缓冲只会是非压缩颜色格式，表里这些格式 GAL 与 Metal 每像素字节数相同）：
    // 10-18 八方2 交来的贴图缓冲 info.bpp = 1（4 字节格式宽 64 只给行距 64，Metal 校验要 256 → 断言崩）。这是参照原样：Ryujinx 顶点阶段转计算的模拟路径
    // （Engine/Threed/ComputeDraw/VtgAsComputeContext.cs）给贴图缓冲建 TextureCreateInfo 时 bytesPerPixel 写死 1，Vulkan 后端对贴图缓冲只按格式算——同样不看 info.bpp
    int bpp = tbuf_elem_size(pf);
    if (!bpp) { GRED_ONCE("SetStorage：贴图缓冲格式 %d（Metal %lu）不是可作贴图缓冲的颜色格式，不挂", t->info.format, (unsigned long)pf); return; }
    NSUInteger align = [g_gdev minimumTextureBufferAlignmentForPixelFormat:pf];
    if (align && moff % align) { GLOG("【红】贴图缓冲偏移 %llu 不是 %lu 的倍数（缓冲 %u 偏移 %d）", (unsigned long long)moff, (unsigned long)align, r->buf, r->offset); return; }
    NSUInteger w = (NSUInteger)(r->size / bpp);
    if (!w || moff + w * bpp > b.length) { GLOG("【红】贴图缓冲区间无效：缓冲 %u 偏移 %d 大小 %d（MTLBuffer 长 %lu）", r->buf, r->offset, r->size, (unsigned long)b.length); return; }
    @autoreleasepool {
        MTLTextureUsage u = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite; u |= atomic_usage(pf, u);
        MTLTextureDescriptor *d = [MTLTextureDescriptor textureBufferDescriptorWithPixelFormat:pf width:w resourceOptions:b.resourceOptions usage:u];
        NSUInteger bpr = w * bpp; if (align) bpr = (bpr + align - 1) / align * align;
        id<MTLTexture> nt = [b newTextureWithDescriptor:d offset:moff bytesPerRow:bpr];
        if (!nt) { GLOG("【红】由缓冲建贴图缓冲失败：格式 %d 宽 %lu", t->info.format, (unsigned long)w); return; }
        if (t->tex) gal_release_later(t->tex, 0);
        t->tex = nt; t->smp = nt; t->root = nt; t->storage = *r; t->gen++; gal_tex_rid(t);
    }
}

static uint64_t rid_of(id<MTLTexture> m) { if (!m) return 0; MTLResourceID r = m.gpuResourceID; uint64_t v; memcpy(&v, &r, 8); return v; }
void gal_tex_rid(gal_tex *t) { t->rid_tex = rid_of(t->tex); t->rid_smp = rid_of(t->smp); }

// ---------- 采样器 ----------
// min_lod / lod_bias：帧缓冲读取判「采样落在 0 级」用（gal_draw.m）；alt / f：自定义边框色（gal_border.m）的副份采样器与混合系数，alt = nil 即不是自定义色
// lb：着色器替采样器加的 LOD 偏置（本机 GPU 原生偏置不生效时，gal_border.m 采样辅助经边框表加上；原生或没有偏置 = 0）
typedef struct { id<MTLSamplerState> s, alt; int live; float min_lod, lod_bias; float f[4]; float lb; } smp_ent;
static smp_ent *g_smp; static uint32_t g_nsmp, g_capsmp; static uint32_t *g_smp_free; static uint32_t g_nsmp_free, g_capsmp_free;
id<MTLSamplerState> gal_sampler_get(uint32_t id_) { return id_ && id_ < g_nsmp && g_smp[id_].live ? g_smp[id_].s : nil; }
// 采样器的最小 LOD 与 LOD 偏移（无效编号返回 0）
int gal_sampler_lod(uint32_t id_, float *min_lod, float *lod_bias) { if (!gal_sampler_get(id_)) return 0; *min_lod = g_smp[id_].min_lod; *lod_bias = g_smp[id_].lod_bias; return 1; }
uint32_t g_smp_custom;   // 在用的着色器模拟采样器个数：自定义边框色或着色器加 LOD 偏置（0 时绘制不查边框表）
// 这个采样器要着色器模拟的部分：*alt / c = 自定义边框色的副份与混合系数（不是自定义色：*alt = 0），*lb = 着色器加的 LOD 偏置；两样都没有返回 0
int gal_sampler_border(uint32_t id_, uint64_t *alt, float c[4], float *lb) {
    if (!gal_sampler_get(id_) || (!g_smp[id_].alt && !g_smp[id_].lb)) return 0;
    *alt = 0; memset(c, 0, 16); *lb = g_smp[id_].lb;
    if (g_smp[id_].alt) { MTLResourceID r = g_smp[id_].alt.gpuResourceID; memcpy(alt, &r, 8); memcpy(c, g_smp[id_].f, 16); }
    return 1;
}
// LOD 偏置交给着色器加（gal_border.m）：有偏置、本机 GPU 原生偏置不生效（或 S2A_SAMP_EMU=1）。比较采样不经采样辅助（gal_border.m 不改写 sample_compare），报红、偏置丢掉
static int lodbias_emu(const nxgal_sampler_info *i) { return i->lod_bias != 0 && !s2a_lodbias_native(g_gdev); }

static MTLSamplerAddressMode addr_mode(int32_t m) {
    switch (m) {   // AddressMode：0 Repeat 1 MirroredRepeat 2 ClampToEdge 3 ClampToBorder 4 Clamp 5 MirrorClampToEdge 6 MirrorClampToBorder 7 MirrorClamp
        case 0: return MTLSamplerAddressModeRepeat; case 1: return MTLSamplerAddressModeMirrorRepeat;
        case 2: return MTLSamplerAddressModeClampToEdge; case 3: return MTLSamplerAddressModeClampToBorderColor;
        case 4: return MTLSamplerAddressModeClampToEdge;          // GL_CLAMP：Vulkan 同样落到 ClampToEdge
        case 5: return MTLSamplerAddressModeMirrorClampToEdge;
        case 6: return MTLSamplerAddressModeClampToBorderColor;   // Metal 无 mirror-clamp-to-border：同 Vulkan 落到 ClampToBorder
        case 7: return MTLSamplerAddressModeMirrorClampToEdge;    // GL_MIRROR_CLAMP：Vulkan 落 ClampToEdge（自注 TODO），这里取更近的 MirrorClampToEdge
    }
    GRED_ONCE("采样器：未知寻址模式 %d", m); return MTLSamplerAddressModeClampToEdge;
}
static MTLCompareFunction cmp_fn(int32_t op) {
    if (op >= 0x200 && op <= 0x207) op = op - 0x200 + 1;   // *Gl 变体
    switch (op) {
        case 1: return MTLCompareFunctionNever; case 2: return MTLCompareFunctionLess; case 3: return MTLCompareFunctionEqual;
        case 4: return MTLCompareFunctionLessEqual; case 5: return MTLCompareFunctionGreater; case 6: return MTLCompareFunctionNotEqual;
        case 7: return MTLCompareFunctionGreaterEqual; case 8: return MTLCompareFunctionAlways;
    }
    GRED_ONCE("采样器：未知比较函数 %d", op); return MTLCompareFunctionNever;
}

static int uses_border(const nxgal_sampler_info *i) { return addr_mode(i->addr_u) == MTLSamplerAddressModeClampToBorderColor || addr_mode(i->addr_v) == MTLSamplerAddressModeClampToBorderColor || addr_mode(i->addr_p) == MTLSamplerAddressModeClampToBorderColor; }
// 自定义边框色要着色器模拟：有边框寻址、不是比较采样、不是三种之一
int gal_sampler_border_custom(const nxgal_sampler_info *i) {
    if (!uses_border(i) || i->compare_mode == 1) return 0;
    const float *b = i->border;
    int tb = !b[0] && !b[1] && !b[2] && !b[3], ob = !b[0] && !b[1] && !b[2] && b[3] == 1, ow = b[0] == 1 && b[1] == 1 && b[2] == 1 && b[3] == 1;
    return !(tb || ob || ow);
}
// 主份边框色：0 透明黑 1 不透明黑 2 不透明白
int gal_sampler_border_kind(const nxgal_sampler_info *i) {
    static const float bc[3][4] = {{0, 0, 0, 0}, {0, 0, 0, 1}, {1, 1, 1, 1}};
    const float *b = i->border;
    // 深度比较只比 R：R 是 0 / 1 时最近的三种之一 R 相同、结果精确；否则照最近的近似并报红（选法同旧：RGBA 欧氏距离最近，不改已有采样器的取色）
    if (i->compare_mode == 1 && uses_border(i) && b[0] != 0 && b[0] != 1) GRED_ONCE("比较采样器边框深度 %g 不是 0 / 1，按最接近的三种之一近似", b[0]);
    int k0 = gal_sampler_border_custom(i) ? 1 : 0, best = 0; float bd = 1e30f;
    for (int k = 0; k < 3; k++) { if (k0 && k == 1) continue; float s = 0; for (int c = 0; c < 4; c++) { float x = b[c] - bc[k][c]; s += x * x; } if (s < bd) { bd = s; best = k; } }
    return best;
}
MTLSamplerDescriptor *gal_sampler_desc(const nxgal_sampler_info *i) {
    MTLSamplerDescriptor *d = [MTLSamplerDescriptor new];
    // MinFilter：1 Nearest 2 Linear（不用多级 = Vulkan 的 maxLod 0.25 只取基级）3 NN 4 LN 5 NL 6 LL
    switch (i->min_filter) {
        case 1: d.minFilter = MTLSamplerMinMagFilterNearest; d.mipFilter = MTLSamplerMipFilterNotMipmapped; break;
        case 2: d.minFilter = MTLSamplerMinMagFilterLinear;  d.mipFilter = MTLSamplerMipFilterNotMipmapped; break;
        case 3: d.minFilter = MTLSamplerMinMagFilterNearest; d.mipFilter = MTLSamplerMipFilterNearest; break;
        case 4: d.minFilter = MTLSamplerMinMagFilterLinear;  d.mipFilter = MTLSamplerMipFilterNearest; break;
        case 5: d.minFilter = MTLSamplerMinMagFilterNearest; d.mipFilter = MTLSamplerMipFilterLinear; break;
        case 6: d.minFilter = MTLSamplerMinMagFilterLinear;  d.mipFilter = MTLSamplerMipFilterLinear; break;
        default: GRED_ONCE("采样器：未知缩小过滤 %d", i->min_filter);
    }
    d.magFilter = i->mag_filter == 2 ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
    d.sAddressMode = addr_mode(i->addr_u); d.tAddressMode = addr_mode(i->addr_v); d.rAddressMode = addr_mode(i->addr_p);
    if (i->compare_mode == 1) d.compareFunction = cmp_fn(i->compare_op);
    // 边框颜色：Metal 只有透明黑 / 不透明黑 / 不透明白（Ryujinx Metal 后端、MoltenVK 都只取最近的一种）。
    //   正好是三者之一：直接用。比较采样只比 R（深度）：R 为 0 / 1 时三者之一已精确，否则取最近并报红。
    //   其余自定义色（有边框寻址）：着色器模拟（gal_border.m）——这里出主份（透明黑 / 不透明白里较近的一个，未改写的着色器照它近似），
    //   nxgal_sampler_create 另建副份（另一个）并算混合系数；没有边框寻址的边框色用不到，取最近即可
    switch (gal_sampler_border_kind(i)) {
        case 0: d.borderColor = MTLSamplerBorderColorTransparentBlack; break;
        case 1: d.borderColor = MTLSamplerBorderColorOpaqueBlack; break;
        default: d.borderColor = MTLSamplerBorderColorOpaqueWhite; break;
    }
    // 各向异性：Vulkan maxAnisotropy != 1 即开；Metal 取整 1–16
    float an = i->max_aniso; int ai = (int)(an + 0.5f); d.maxAnisotropy = ai < 1 ? 1 : ai > 16 ? 16 : ai;
    float lo = i->min_lod, hi = i->max_lod; if (hi < lo) hi = lo;
    d.lodMinClamp = lo; d.lodMaxClamp = hi;
    // 采样器级 LOD 偏置（macOS / iOS 26 起）：本机 GPU 实测生效（s2a_lodbias_native）就设在采样器上；不生效（Apple10 以前的部分 GPU，如 M3）不设，
    //   由着色器把偏置加到每次采样的 LOD 上（lodbias_emu → 边框表 lb → gal_border.m s2a_bsample），画面同原生
    if (i->lod_bias != 0 && !lodbias_emu(i)) { if (@available(macOS 26.0, iOS 26.0, *)) d.lodBias = i->lod_bias; }
    if (lodbias_emu(i) && i->compare_mode == 1) GRED_ONCE("比较采样器带 LOD 偏置 %g，本机 GPU 原生偏置不生效、比较采样不经着色器模拟：偏置丢掉（只影响阴影贴图的清晰度）", i->lod_bias);
    // 无缝立方体：Metal 立方体采样恒为无缝，非无缝（GL 缺省）做不到；只记一次差异
    if (!i->seamless_cube) GRED_ONCE("采样器要求非无缝立方体采样，Metal 恒为无缝（只影响立方体贴图边缘过滤）");
    d.normalizedCoordinates = YES;
    d.supportArgumentBuffers = YES;   // 参数缓冲里写 gpuResourceID 必须
    return d;
}

NXGAL_API uint32_t nxgal_sampler_create(const nxgal_sampler_info *info) { GAL_API_LOCK();
    g_obj_gen++;   // 同号换对象：按集复用的参数缓冲作废
    @autoreleasepool {
        MTLSamplerDescriptor *sd = gal_sampler_desc(info);
        id<MTLSamplerState> s = [g_gdev newSamplerStateWithDescriptor:sd], alt = nil;
        if (!s) { GLOG("【红】建采样器失败"); return 0; }
        // 自定义边框色：副份 = 另一种（透明黑 ↔ 不透明白），混合系数 f = (自定义色 − 主份色) / (副份色 − 主份色)，逐分量（两者逐分量差 ±1）
        float f[4] = {0, 0, 0, 0};
        if (gal_sampler_border_custom(info)) {
            int white = sd.borderColor == MTLSamplerBorderColorOpaqueWhite;
            sd.borderColor = white ? MTLSamplerBorderColorTransparentBlack : MTLSamplerBorderColorOpaqueWhite;
            alt = [g_gdev newSamplerStateWithDescriptor:sd];
            if (!alt) GLOG("【红】建自定义边框色副份采样器失败（按主份近似）");
            for (int c = 0; c < 4; c++) f[c] = white ? 1 - info->border[c] : info->border[c];
            static int said; if (alt && !said++) GLOG("采样器自定义边框色 (%g,%g,%g,%g)：着色器模拟（主份%s + 副份%s 混合，gal_border.m）", info->border[0], info->border[1], info->border[2], info->border[3],
                                                 white ? "不透明白" : "透明黑", white ? "透明黑" : "不透明白");
            if (alt) g_smp_custom++;
        }
        float lb = lodbias_emu(info) && info->compare_mode != 1 ? info->lod_bias : 0;   // 着色器加的 LOD 偏置（比较采样器不经采样辅助，见 gal_sampler_desc）
        if (lb) { g_smp_custom++; static int said; if (!said++) GLOG("采样器 LOD 偏置 %g：本机 GPU 原生偏置不生效，着色器模拟（gal_border.m）", lb); }
        uint32_t sid;
        if (g_nsmp_free) sid = g_smp_free[--g_nsmp_free];
        else {
            if (!g_nsmp) g_nsmp = 1;
            if (g_nsmp >= g_capsmp) { g_capsmp = g_capsmp ? g_capsmp * 2 : 256; g_smp = realloc(g_smp, g_capsmp * sizeof *g_smp); memset((void *)(g_smp + g_nsmp), 0, (g_capsmp - g_nsmp) * sizeof *g_smp); }
            sid = g_nsmp++;
        }
        g_smp[sid] = (smp_ent){s, alt, 1, info->min_lod, info->lod_bias, {f[0], f[1], f[2], f[3]}, lb};
        return sid;
    }
}
NXGAL_API void nxgal_sampler_release(uint32_t sid) { GAL_API_LOCK();
    g_obj_gen++;   // 同号换对象：按集复用的参数缓冲作废
    if (!gal_sampler_get(sid)) return;
    gal_release_later(g_smp[sid].s, 0); g_smp[sid].s = nil; g_smp[sid].live = 0;
    if (g_smp[sid].alt) { gal_release_later(g_smp[sid].alt, 0); g_smp[sid].alt = nil; g_smp_custom--; }
    if (g_smp[sid].lb) { g_smp[sid].lb = 0; g_smp_custom--; }
    if (g_nsmp_free == g_capsmp_free) { g_capsmp_free = g_capsmp_free ? g_capsmp_free * 2 : 256; g_smp_free = realloc(g_smp_free, g_capsmp_free * sizeof *g_smp_free); }
    g_smp_free[g_nsmp_free++] = sid;
}

// ---------- 贴图 / 图像数组（ITextureArray / IImageArray）----------
// 只存编号；内容改动 serial 取全局单调计数（编号复用后也不会与旧值撞上），绑定处据 (编号, serial) 判断要不要重写参数缓冲。
static gal_tarr *g_tarr; static uint32_t g_ntarr, g_captarr; static uint32_t *g_tarr_free; static uint32_t g_ntarr_free, g_captarr_free;
static uint32_t g_tarr_serial;
gal_tarr *gal_tarr_get(uint32_t a) { return a && a < g_ntarr && g_tarr[a].live ? &g_tarr[a] : NULL; }
NXGAL_API uint32_t nxgal_tarr_create(int32_t size, int32_t is_buffer, int32_t is_image) { GAL_API_LOCK();
    if (size < 0) size = 0;
    uint32_t a;
    if (g_ntarr_free) a = g_tarr_free[--g_ntarr_free];
    else {
        if (!g_ntarr) g_ntarr = 1;
        if (g_ntarr >= g_captarr) { g_captarr = g_captarr ? g_captarr * 2 : 64; g_tarr = realloc(g_tarr, g_captarr * sizeof *g_tarr); memset(g_tarr + g_ntarr, 0, (g_captarr - g_ntarr) * sizeof *g_tarr); }
        a = g_ntarr++;
    }
    g_tarr[a] = (gal_tarr){calloc((size_t)size + 1, sizeof(uint32_t)), is_image ? NULL : calloc((size_t)size + 1, sizeof(uint32_t)), size, is_buffer != 0, is_image != 0, 1, ++g_tarr_serial};
    return a;
}
static void tarr_set(uint32_t a, int32_t index, const uint32_t *v, int32_t n, int smp) {
    gal_tarr *t = gal_tarr_get(a); if (!t) { GRED_ONCE("贴图数组 %u 无效", a); return; }
    uint32_t *dst = smp ? t->smp : t->tex;
    if (!dst) { GRED_ONCE("图像数组 %u 不带采样器", a); return; }
    if (index < 0 || index >= t->size) { GRED_ONCE("贴图数组 %u 下标 %d 越界（大小 %d）", a, index, t->size); return; }
    if (n > t->size - index) { GRED_ONCE("贴图数组 %u 写 %d 项越界，截到 %d", a, n, t->size - index); n = t->size - index; }
    if (n <= 0) return;
    if (!memcmp(dst + index, v, (size_t)n * sizeof *v)) return;   // 内容没变不递增
    memcpy(dst + index, v, (size_t)n * sizeof *v);
    t->serial = ++g_tarr_serial; g_obj_gen++;
    if (!smp && g_uw_on) for (int32_t k = 0; k < n; k++) { if (t->is_image) gal_uw_write(v[k]); else gal_uw_sample(v[k], "贴图数组"); }
    // 自定义边框色（gal_border.m）只改写单个采样器；采样器数组里的照主份（三种标准色之一）近似。图形接口盘点 20：先报出来、看哪款真用到再补数组改写（报一次即停查）
    static int arr_border_seen;
    if (smp && !arr_border_seen)
        for (int32_t k = 0; k < n; k++) { uint64_t alt; float f[4], lb;
            if (v[k] && gal_sampler_border(v[k], &alt, f, &lb)) { arr_border_seen = 1;
                GRED_ONCE("要着色器模拟的采样器 %u（自定义边框色 %s %g %g %g %g、LOD 偏置 %g）进了采样器数组 %u[%d]：数组不走着色器模拟，边框色按最近的标准色近似、偏置丢掉（图形接口盘点 20）",
                          v[k], alt ? "有" : "无", f[0], f[1], f[2], f[3], lb, a, index + k); break; } }
}
NXGAL_API void nxgal_tarr_set_textures(uint32_t a, int32_t index, const uint32_t *tex, int32_t n) { GAL_API_LOCK(); tarr_set(a, index, tex, n, 0); }
NXGAL_API void nxgal_tarr_set_samplers(uint32_t a, int32_t index, const uint32_t *smp, int32_t n) { GAL_API_LOCK(); tarr_set(a, index, smp, n, 1); }
NXGAL_API void nxgal_tarr_release(uint32_t a) { GAL_API_LOCK();
    g_obj_gen++;   // 同号换对象：按集复用的参数缓冲作废
    gal_tarr *t = gal_tarr_get(a); if (!t) return;
    free(t->tex); free(t->smp); memset(t, 0, sizeof *t);
    if (g_ntarr_free == g_captarr_free) { g_captarr_free = g_captarr_free ? g_captarr_free * 2 : 64; g_tarr_free = realloc(g_tarr_free, g_captarr_free * sizeof *g_tarr_free); }
    g_tarr_free[g_ntarr_free++] = a;
}
// Called only after GPU completion, deferred-object reaping and all API producer joins.
void gal_tex_reset_session(void) {
    pthread_mutex_lock(&g_ul_mu);
    g_ul_generation++;
    for (uint32_t i = 1; i < g_nul; i++)
        if (g_ul[i].buf) { (void)(__bridge_transfer id)g_ul[i].buf; g_ul[i].buf = NULL; }
    for (int i = 0; i < g_nulc; i++) {
        id<MTLBuffer> buffer = (__bridge_transfer id<MTLBuffer>)g_ulc[i].buf;
        if (g_ulc[i].resident) gal_res_remove(buffer);
        g_ulc[i].buf = NULL;
    }
    free(g_ulc); g_ulc = NULL; g_nulc = g_capulc = 0; g_ulc_cur = -1;
    free(g_ul); g_ul = NULL; g_nul = 1; g_cap_ul = 0;
    free(g_ul_free); g_ul_free = NULL; g_nul_free = g_cap_ul_free = 0; g_ul_rents = 0;
    pthread_mutex_unlock(&g_ul_mu);
    for (uint32_t i = 1; i < g_ntex; i++) {
        gal_tex *texture = &g_tex[i];
        if (texture->live && texture->tex && !texture->parent && texture->info.target != 9) gal_res_remove(texture->tex);
        texture->smp = nil; texture->tex = nil; texture->root = nil;
    }
    free(g_tex); g_tex = NULL; g_ntex = g_captex = 0;
    free(g_tex_free); g_tex_free = NULL; g_ntex_free = g_cap_free = 0;
    for (uint32_t i = 1; i < g_nsmp; i++) { g_smp[i].s = nil; g_smp[i].alt = nil; }
    free(g_smp); g_smp = NULL; g_nsmp = g_capsmp = 0;
    free(g_smp_free); g_smp_free = NULL; g_nsmp_free = g_capsmp_free = 0; g_smp_custom = 0;
    for (uint32_t i = 1; i < g_ntarr; i++) { free(g_tarr[i].tex); free(g_tarr[i].smp); }
    free(g_tarr); g_tarr = NULL; g_ntarr = g_captarr = 0;
    free(g_tarr_free); g_tarr_free = NULL; g_ntarr_free = g_captarr_free = g_tarr_serial = 0;
    // Argument tables contain raw texture/buffer addresses and must never survive a game.
    // Helper libraries/PSOs/samplers contain no guest resources and are device cache entries.
    g_tvt = nil; g_tft = nil; g_tct = nil;
    g_up_pre = g_cp_pre = g_cp_hit = 0; g_uw_on = -1; g_uw_n = g_uw_tex = 0;
}
GAL_MTL4_ZONE_END
