// GAL Metal 后端：第 5 块「管线状态」——GAL 状态原样记录 + 枚举翻译 + 渲染管线 / 深度模板状态缓存 + 绘制前应用动态状态。
// 语义对照 Ryujinx Vulkan 后端（PipelineBase / PipelineState / EnumConversion）。Metal 与 Vulkan 的两处坐标差：
//   ① 视口：Metal 规范化坐标 Y 朝上，Vulkan 朝下 → 视口原点放到 y + h、高取负（与社区 Metal 后端同），帧缓冲里落点与 Vulkan 一致；
//   ② 正面绕序：Metal 与 Vulkan 都按帧缓冲坐标判绕序；GAL 的 FrontFace 按 OpenGL（Y 朝上）定义，Ryujinx Vulkan 后端下发时取反
//     （EnumConversion：GAL Clockwise → VK CounterClockwise），我们照做。10-18 曾按「GAL 值 = Vulkan 值」手算期望、把取反判成错，
//     动森录像对拍（关剔除即全一致）证明前提错了——参照语义以 Ryujinx Vulkan 后端实际下发的值为准，不以 Vulkan 规范直套 GAL 枚举。
// 管线：整编键 = 程序哈希 + 附件格式 / 采样数 + 混合 + 写掩码 + 顶点布局（步进函数）+ 拓扑类 + 光栅化开关 + alpha-to-coverage。
//   顶点缓冲跨度不进键（参数表 setAddress:attributeStride: 动态给）。
#import "gal_draw_internal.h"
#include "gal_formats.h"
#include <string.h>
#include <stdlib.h>
#include <pthread.h>
#include <stdatomic.h>
#include <os/lock.h>
#include <mach/mach.h>
#include <objc/runtime.h>

GAL_MTL4_ZONE_BEGIN   // Metal 4 可用性区（gal_internal.h）
gal_state g_gs;

// ---------- 枚举翻译 ----------
MTLCompareFunction gal_cmp(int32_t op) {
    switch (op) {
        case 1: case 0x200: return MTLCompareFunctionNever;   case 2: case 0x201: return MTLCompareFunctionLess;
        case 3: case 0x202: return MTLCompareFunctionEqual;   case 4: case 0x203: return MTLCompareFunctionLessEqual;
        case 5: case 0x204: return MTLCompareFunctionGreater; case 6: case 0x205: return MTLCompareFunctionNotEqual;
        case 7: case 0x206: return MTLCompareFunctionGreaterEqual; case 8: case 0x207: return MTLCompareFunctionAlways;
    }
    return MTLCompareFunctionAlways;
}
static MTLStencilOperation sop(int32_t op) {
    switch (op) {
        case 1: case 0x1e00: return MTLStencilOperationKeep;      case 2: case 0x0: return MTLStencilOperationZero;
        case 3: case 0x1e01: return MTLStencilOperationReplace;   case 4: case 0x1e02: return MTLStencilOperationIncrementClamp;
        case 5: case 0x1e03: return MTLStencilOperationDecrementClamp; case 6: case 0x150a: return MTLStencilOperationInvert;
        case 7: case 0x8507: return MTLStencilOperationIncrementWrap;  case 8: case 0x8508: return MTLStencilOperationDecrementWrap;
    }
    return MTLStencilOperationKeep;
}
static MTLBlendOperation bop(int32_t op) {
    switch (op) {
        case 1: case 0x8006: return MTLBlendOperationAdd; case 2: case 0x800a: return MTLBlendOperationSubtract;
        case 3: case 0x800b: return MTLBlendOperationReverseSubtract; case 4: case 0x8007: return MTLBlendOperationMin;
        case 5: case 0x8008: return MTLBlendOperationMax;
    }
    return MTLBlendOperationAdd;
}
static MTLBlendFactor bfac(int32_t f) {
    switch (f) {
        case 1: case 0x4000: return MTLBlendFactorZero; case 2: case 0x4001: return MTLBlendFactorOne;
        case 3: case 0x4300: return MTLBlendFactorSourceColor; case 4: case 0x4301: return MTLBlendFactorOneMinusSourceColor;
        case 5: case 0x4302: return MTLBlendFactorSourceAlpha; case 6: case 0x4303: return MTLBlendFactorOneMinusSourceAlpha;
        case 7: case 0x4304: return MTLBlendFactorDestinationAlpha; case 8: case 0x4305: return MTLBlendFactorOneMinusDestinationAlpha;
        case 9: case 0x4306: return MTLBlendFactorDestinationColor; case 10: case 0x4307: return MTLBlendFactorOneMinusDestinationColor;
        case 11: case 0x4308: return MTLBlendFactorSourceAlphaSaturated;
        case 0x10: case 0xc900: return MTLBlendFactorSource1Color; case 0x11: case 0xc901: return MTLBlendFactorOneMinusSource1Color;
        case 0x12: case 0xc902: return MTLBlendFactorSource1Alpha; case 0x13: case 0xc903: return MTLBlendFactorOneMinusSource1Alpha;
        case 0xc001: return MTLBlendFactorBlendColor; case 0xc002: return MTLBlendFactorOneMinusBlendColor;
        case 0xc003: return MTLBlendFactorBlendAlpha; case 0xc004: return MTLBlendFactorOneMinusBlendAlpha;
    }
    return MTLBlendFactorOne;
}
// GAL Format → 顶点格式（Capabilities 报 supportsScaledVertexFormats = false：旧口径着色器按整数读缩放格式、自己补换算）
static MTLVertexFormat vfmt(int32_t f) {
    static const MTLVertexFormat t[F_COUNT] = {
        [F_R8Unorm] = MTLVertexFormatUCharNormalized, [F_R8Snorm] = MTLVertexFormatCharNormalized, [F_R8Uint] = MTLVertexFormatUChar, [F_R8Sint] = MTLVertexFormatChar,
        [F_R16Float] = MTLVertexFormatHalf, [F_R16Unorm] = MTLVertexFormatUShortNormalized, [F_R16Snorm] = MTLVertexFormatShortNormalized, [F_R16Uint] = MTLVertexFormatUShort, [F_R16Sint] = MTLVertexFormatShort,
        [F_R32Float] = MTLVertexFormatFloat, [F_R32Uint] = MTLVertexFormatUInt, [F_R32Sint] = MTLVertexFormatInt,
        [F_R8G8Unorm] = MTLVertexFormatUChar2Normalized, [F_R8G8Snorm] = MTLVertexFormatChar2Normalized, [F_R8G8Uint] = MTLVertexFormatUChar2, [F_R8G8Sint] = MTLVertexFormatChar2,
        [F_R16G16Float] = MTLVertexFormatHalf2, [F_R16G16Unorm] = MTLVertexFormatUShort2Normalized, [F_R16G16Snorm] = MTLVertexFormatShort2Normalized, [F_R16G16Uint] = MTLVertexFormatUShort2, [F_R16G16Sint] = MTLVertexFormatShort2,
        [F_R32G32Float] = MTLVertexFormatFloat2, [F_R32G32Uint] = MTLVertexFormatUInt2, [F_R32G32Sint] = MTLVertexFormatInt2,
        [F_R8G8B8Unorm] = MTLVertexFormatUChar3Normalized, [F_R8G8B8Snorm] = MTLVertexFormatChar3Normalized, [F_R8G8B8Uint] = MTLVertexFormatUChar3, [F_R8G8B8Sint] = MTLVertexFormatChar3,
        [F_R16G16B16Float] = MTLVertexFormatHalf3, [F_R16G16B16Unorm] = MTLVertexFormatUShort3Normalized, [F_R16G16B16Snorm] = MTLVertexFormatShort3Normalized, [F_R16G16B16Uint] = MTLVertexFormatUShort3, [F_R16G16B16Sint] = MTLVertexFormatShort3,
        [F_R32G32B32Float] = MTLVertexFormatFloat3, [F_R32G32B32Uint] = MTLVertexFormatUInt3, [F_R32G32B32Sint] = MTLVertexFormatInt3,
        [F_R8G8B8A8Unorm] = MTLVertexFormatUChar4Normalized, [F_R8G8B8A8Snorm] = MTLVertexFormatChar4Normalized, [F_R8G8B8A8Uint] = MTLVertexFormatUChar4, [F_R8G8B8A8Sint] = MTLVertexFormatChar4,
        [F_R16G16B16A16Float] = MTLVertexFormatHalf4, [F_R16G16B16A16Unorm] = MTLVertexFormatUShort4Normalized, [F_R16G16B16A16Snorm] = MTLVertexFormatShort4Normalized,
        [F_R16G16B16A16Uint] = MTLVertexFormatUShort4, [F_R16G16B16A16Sint] = MTLVertexFormatShort4,
        [F_R32G32B32A32Float] = MTLVertexFormatFloat4, [F_R32G32B32A32Uint] = MTLVertexFormatUInt4, [F_R32G32B32A32Sint] = MTLVertexFormatInt4,
        [F_R10G10B10A2Unorm] = MTLVertexFormatUInt1010102Normalized, [F_R10G10B10A2Snorm] = MTLVertexFormatInt1010102Normalized,
        [F_R11G11B10Float] = MTLVertexFormatFloatRG11B10, [F_R9G9B9E5Float] = MTLVertexFormatFloatRGB9E5,
        [F_B8G8R8A8Unorm] = MTLVertexFormatUChar4Normalized_BGRA,
        [F_A8B8G8R8Uint] = MTLVertexFormatUChar4,   // 小端内存字节序 R G B A，同 R8G8B8A8Uint
        // 缩放整数（能力表报顶点自取时 Gpu 层原样交来，Ryujinx 补丁 vattr-raw）：顶点描述符路径只服务按类型声明的旧口径着色器（整数读 + 着色器补换算），
        // 映射成同宽整数格式，等于原先 Gpu 层的转换；原始位着色器一律自取（gal_vpull.m），不走这里
        [F_R8Uscaled] = MTLVertexFormatUChar, [F_R8Sscaled] = MTLVertexFormatChar, [F_R16Uscaled] = MTLVertexFormatUShort, [F_R16Sscaled] = MTLVertexFormatShort,
        [F_R32Uscaled] = MTLVertexFormatUInt, [F_R32Sscaled] = MTLVertexFormatInt,
        [F_R8G8Uscaled] = MTLVertexFormatUChar2, [F_R8G8Sscaled] = MTLVertexFormatChar2, [F_R16G16Uscaled] = MTLVertexFormatUShort2, [F_R16G16Sscaled] = MTLVertexFormatShort2,
        [F_R32G32Uscaled] = MTLVertexFormatUInt2, [F_R32G32Sscaled] = MTLVertexFormatInt2,
        [F_R8G8B8Uscaled] = MTLVertexFormatUChar3, [F_R8G8B8Sscaled] = MTLVertexFormatChar3, [F_R16G16B16Uscaled] = MTLVertexFormatUShort3, [F_R16G16B16Sscaled] = MTLVertexFormatShort3,
        [F_R32G32B32Uscaled] = MTLVertexFormatUInt3, [F_R32G32B32Sscaled] = MTLVertexFormatInt3,
        [F_R8G8B8A8Uscaled] = MTLVertexFormatUChar4, [F_R8G8B8A8Sscaled] = MTLVertexFormatChar4, [F_R16G16B16A16Uscaled] = MTLVertexFormatUShort4, [F_R16G16B16A16Sscaled] = MTLVertexFormatShort4,
        [F_R32G32B32A32Uscaled] = MTLVertexFormatUInt4, [F_R32G32B32A32Sscaled] = MTLVertexFormatInt4,
    };
    // R10G10B10A2Uint / Sint / Uscaled / Sscaled：Metal 无对应顶点格式（自取支持，gal_vpull.m），顶点描述符路径报红
    return (unsigned)f < F_COUNT ? t[f] : MTLVertexFormatInvalid;
}
// 线宽：只记下来；线拓扑的宽线在绘制处展开（gal_draw.m / gal_wline.m），这里只管多边形线模式（三角形按边画）的宽线：照 1 像素画并报红
float g_line_width = 1; int g_draw_wl; uint64_t g_wide_line_draws[3];
MTLPrimitiveType gal_prim(int32_t topo, int *ok) {
    *ok = 1;
    if (g_line_width > 1.5f && topo >= 4 && g_gs.poly == 0x1b01 && !g_wide_line_draws[2]++) GRED_ONCE("多边形线模式画宽线（线宽 %.1f）：Metal 只有 1 像素线，照 1 像素画", g_line_width);
    switch (topo) {
        case 0: return MTLPrimitiveTypePoint; case 1: return MTLPrimitiveTypeLine; case 3: return MTLPrimitiveTypeLineStrip;
        case 4: return MTLPrimitiveTypeTriangle; case 5: return MTLPrimitiveTypeTriangleStrip;
        case 8: return MTLPrimitiveTypeTriangleStrip;   // QuadStrip：顶点顺序与三角带一致，几何相同
        case 2: if (g_line_width <= 1.5f) GRED_ONCE("拓扑 LineLoop：按 LineStrip 画（缺最后一段闭合边）"); return MTLPrimitiveTypeLineStrip;   // 宽线环由展开画闭合边（gal_draw.m wide_line_draw）
        case 6: case 7: case 9: return MTLPrimitiveTypeTriangle;   // TriangleFan / Quads / Polygon：绘制处换成三角形索引（gal_draw.m）
    }
    *ok = 0; return MTLPrimitiveTypeTriangle;
}
static MTLPrimitiveTopologyClass topo_class(int32_t topo) {
    switch (topo) { case 0: return MTLPrimitiveTopologyClassPoint; case 1: case 2: case 3: return MTLPrimitiveTopologyClassLine; }
    return MTLPrimitiveTopologyClassTriangle;
}

// ---------- 状态设置（只记录，绘制前统一应用）----------
#define DIRTY(f) (g_gs.dirty |= (f))
NXGAL_API void nxgal_set_program(uint32_t prog) { GAL_API_LOCK(); if (g_gs.prog != prog) { g_gs.prog = prog; DIRTY(GS_PSO | GS_ARGS); } }
NXGAL_API void nxgal_set_blend(int32_t index, const nxgal_blend *b) { GAL_API_LOCK(); if (index >= 0 && index < 8) { g_gs.blend[index] = *b; DIRTY(GS_PSO | GS_DYN); } }
NXGAL_API void nxgal_set_blend_advanced(int32_t op, int32_t overlap, int32_t src_premul) { GAL_API_LOCK(); GRED_ONCE("高级混合（op %d）未实现（第 8 块），按普通混合画", op); }
NXGAL_API void nxgal_set_color_masks(const uint32_t *masks, int32_t n) { GAL_API_LOCK(); for (int i = 0; i < 8; i++) g_gs.mask[i] = i < n ? masks[i] & 0xf : 0xf; DIRTY(GS_PSO); gal_pass_masks_changed(); }
uint32_t gal_state_color_mask(int i) { return i >= 0 && i < 8 ? g_gs.mask[i] : 0xf; }
NXGAL_API void nxgal_set_depth_bias(int32_t enables, float factor, float units, float clamp) { GAL_API_LOCK(); g_gs.bias_en = enables; g_gs.bias_factor = factor; g_gs.bias_units = units; g_gs.bias_clamp = clamp; DIRTY(GS_DYN); }
NXGAL_API void nxgal_set_depth_clamp(int32_t clamp) { GAL_API_LOCK(); g_gs.depth_clamp = clamp; DIRTY(GS_DYN); }
NXGAL_API void nxgal_set_depth_mode(int32_t mode) { GAL_API_LOCK(); (void)mode; }   // 能力表报 supportsDepthClipControl = false：-1..1 深度由 Gpu 层特化进着色器
NXGAL_API void nxgal_set_depth_test(const nxgal_depth_test *d) { GAL_API_LOCK(); g_gs.depth = *d; DIRTY(GS_DSS); }
NXGAL_API void nxgal_set_stencil_test(const nxgal_stencil *s) { GAL_API_LOCK(); g_gs.stencil = *s; DIRTY(GS_DSS | GS_DYN); }
NXGAL_API void nxgal_set_face_culling(int32_t enable, int32_t face) { GAL_API_LOCK(); g_gs.cull_en = enable; g_gs.cull_face = face; DIRTY(GS_DYN); }
NXGAL_API void nxgal_set_front_face(int32_t ff) { GAL_API_LOCK(); g_gs.front_face = ff; DIRTY(GS_DYN); }
NXGAL_API void nxgal_set_line_params(float width, int32_t smooth) { GAL_API_LOCK(); (void)smooth; g_line_width = width; }
NXGAL_API void nxgal_set_point_params(float size, int32_t program_size, int32_t sprite, int32_t origin) { GAL_API_LOCK(); (void)size; (void)program_size; (void)sprite; (void)origin; }   // 点大小 / 原点由 Gpu 层特化进着色器
// 逻辑运算（10-24 异度神剑3 实局报 0x1507 = OR）：Metal 片元没有逻辑运算。按 Vulkan 规则（Ryujinx Vulkan 后端 LogicOpsAllowed 同口径）：
//   逻辑运算只作用于整数 / 归一化整数目标，浮点与 sRGB 目标照常写（= 复制）——所以只在真有非浮点目标要写时才报红（pso_key_build 判，写明格式）；
//   NOOP（0x1505）= 目标不变，按写掩码 0 精确实现；其余（AND / OR / XOR …）：纯整数目标且程序有逻辑运算入口 s<键>_lo（gal_logicop.m，帧缓冲读取仿真）时
//   管线换 _lo、绘制时绑 S2ALop 参数（GAL_LOP_SLOT，下面常驻表一项）；unorm / snorm 目标与没有 _lo 的程序照旧报红（写明格式类别）、按复制画
// 纯整数颜色格式（Uint / Sint）：Metal 不可混合（iPhone 上建管线时描述符校验直接断言 abort，10-24 异度神剑3 真机首局 RG32Uint / R32Uint）；
//   Vulkan 规定整数附件上的混合被忽略（Ryujinx Vulkan 后端同口径），所以这些目标一律不置混合位（键与描述两处都过滤，旧收集表来的描述也安全）
int gal_fmt_is_int(MTLPixelFormat f) {
    switch (f) {
        case MTLPixelFormatR8Uint: case MTLPixelFormatR8Sint: case MTLPixelFormatR16Uint: case MTLPixelFormatR16Sint: case MTLPixelFormatRG8Uint: case MTLPixelFormatRG8Sint:
        case MTLPixelFormatR32Uint: case MTLPixelFormatR32Sint: case MTLPixelFormatRG16Uint: case MTLPixelFormatRG16Sint: case MTLPixelFormatRGBA8Uint: case MTLPixelFormatRGBA8Sint:
        case MTLPixelFormatRGB10A2Uint: case MTLPixelFormatRG32Uint: case MTLPixelFormatRG32Sint: case MTLPixelFormatRGBA16Uint: case MTLPixelFormatRGBA16Sint:
        case MTLPixelFormatRGBA32Uint: case MTLPixelFormatRGBA32Sint: return 1;
        default: return 0;
    }
}
uint64_t g_int_noblend;   // 整数目标上游戏开着混合、按 Vulkan 忽略的次数（管线键次数；单测读）
static int g_lop_en, g_lop_op;
NXGAL_API void nxgal_set_logic_op(int32_t enable, int32_t op) { GAL_API_LOCK(); if (g_lop_en != !!enable || g_lop_op != op) { g_lop_en = !!enable; g_lop_op = op; DIRTY(GS_PSO); } }

NXGAL_API void nxgal_set_multisample(int32_t a2c, int32_t a2c_dither, int32_t alpha_to_one) { GAL_API_LOCK(); g_gs.a2c = a2c; g_gs.a2one = alpha_to_one; DIRTY(GS_PSO); }
NXGAL_API void nxgal_set_patch_params(int32_t vertices, const float outer[4], const float inner[2]) { GAL_API_LOCK();   // 曲面细分（gal_tess.m）：每片输入控制点数；缺省细分因子只给无 TCS 的程序（未实现，报红）
    g_gs.patch_vertices = vertices; memcpy(g_gs.patch_outer, outer, sizeof g_gs.patch_outer); memcpy(g_gs.patch_inner, inner, sizeof g_gs.patch_inner); }
NXGAL_API void nxgal_set_polygon_mode(int32_t front, int32_t back) { GAL_API_LOCK(); g_gs.poly = front; DIRTY(GS_DYN); }
NXGAL_API void nxgal_set_primitive_restart(int32_t enable, int32_t index) { GAL_API_LOCK();
    // Metal 带状图元始终按全 1 索引重启、列表图元不重启：其他重启值无法表达，首例报红；「关重启但条带索引里有全 1」由 gal_draw.m 零扩成 32 位处理（restart_on / norst16）
    if (enable && index != -1 && index != 0xffff && index != 0xff) GRED_ONCE("图元重启索引 %#x 非全 1，Metal 无法表达", index);
    g_gs.restart = enable;
}
NXGAL_API void nxgal_set_topology(int32_t t) { GAL_API_LOCK(); if (topo_class(t) != topo_class(g_gs.topology)) DIRTY(GS_PSO); g_gs.topology = t; }
NXGAL_API void nxgal_set_rasterizer_discard(int32_t d) { GAL_API_LOCK(); g_gs.discard = d; DIRTY(GS_PSO | GS_DYN); }   // 剪裁随丢弃变（gal_state_apply_dynamic）
NXGAL_API void nxgal_set_user_clip(int32_t index, int32_t enable) { GAL_API_LOCK(); (void)index; (void)enable; }   // 着色器写裁剪距离；Metal 按写出的距离裁，与 Vulkan 后端同为不做额外处理
NXGAL_API void nxgal_set_viewports(const nxgal_viewport *v, int32_t n) { GAL_API_LOCK();
    if (n > 16) n = 16;
    memcpy(g_gs.vp, v, n * sizeof *v); g_gs.nvp = n; DIRTY(GS_DYN);
    for (int i = 0; i < n; i++) if (v[i].swz[0] != 0 || v[i].swz[1] != 2 || v[i].swz[2] != 4 || v[i].swz[3] != 6) { GRED_ONCE("视口交换（swizzle）未实现"); break; }
}
NXGAL_API void nxgal_set_vertex_attribs(const nxgal_vattr *a, int32_t n) { GAL_API_LOCK();
    if (n > 32) n = 32;
    if (n != g_gs.nattr || memcmp(a, g_gs.attr, n * sizeof *a)) { memcpy(g_gs.attr, a, n * sizeof *a); g_gs.nattr = n; DIRTY(GS_PSO); }
}
NXGAL_API void nxgal_set_vertex_buffers(const nxgal_vbuf *b, int32_t n) { GAL_API_LOCK();
    if (n > 16) n = 16;
    for (int i = 0; i < 16; i++) {
        nxgal_vbuf nb; if (i < n) nb = b[i]; else memset(&nb, 0, sizeof nb);
        // 步进函数 / 速率进管线键：每顶点（跨度 > 0）、常量（跨度 0）、每实例（除数 > 0）
        int step_old = g_gs.vb[i].divisor ? 2 : g_gs.vb[i].stride ? 1 : 0, step_new = nb.divisor ? 2 : nb.stride ? 1 : 0;
        if (step_old != step_new || g_gs.vb[i].divisor != nb.divisor) DIRTY(GS_PSO);
        g_gs.vb[i] = nb;
    }
    g_gs.nvb = n; DIRTY(GS_VB);
}
NXGAL_API void nxgal_set_index_buffer(const nxgal_buf_range *r, int32_t type) { GAL_API_LOCK(); g_gs.ib = *r; g_gs.ib_type = type; }
NXGAL_API void nxgal_set_alpha_test(int32_t enable, float ref, int32_t op) { GAL_API_LOCK(); (void)enable; (void)ref; (void)op; }   // Gpu 层特化进着色器（hostSupportsAlphaTest = false 路径）

// 资源绑定：Ryujinx 的绑定号在一个程序的各阶段之间唯一（ResourceCounts 跨阶段累计），按绑定号存即可
uint32_t g_bind_gen = 1, g_obj_gen = 1;
static void set_buf(nxgal_buf_range *slot, uint32_t *gen, const nxgal_buf_range *r) {
    if (memcmp(slot, r, sizeof *r)) { *slot = *r; *gen = ++g_bind_gen; }
}
NXGAL_API void nxgal_set_uniform_buffers(const nxgal_buf_assign *a, int32_t n) { GAL_API_LOCK();
    for (int i = 0; i < n; i++) if ((unsigned)a[i].binding < GS_MAX_BUF) set_buf(&g_gs.ubo[a[i].binding], &g_gs.ubo_gen[a[i].binding], &a[i].r); else GRED_ONCE("常量缓冲绑定号 %d 超出表长 %d", a[i].binding, GS_MAX_BUF);
    DIRTY(GS_ARGS);
}
NXGAL_API void nxgal_set_storage_buffers(const nxgal_buf_assign *a, int32_t n) { GAL_API_LOCK();
    for (int i = 0; i < n; i++) if ((unsigned)a[i].binding < GS_MAX_BUF) set_buf(&g_gs.ssbo[a[i].binding], &g_gs.ssbo_gen[a[i].binding], &a[i].r); else GRED_ONCE("存储缓冲绑定号 %d 超出表长 %d", a[i].binding, GS_MAX_BUF);
    DIRTY(GS_ARGS);
}
NXGAL_API void nxgal_set_texture_sampler(int32_t stage, int32_t binding, uint32_t tex, uint32_t smp) { GAL_API_LOCK(); gal_uw_sample(tex, "单绑定");
    (void)stage;
    // 贴图缓冲进另一张表、不动普通贴图与采样器；0 两张都清（同 Ryujinx Vulkan SetTextureAndSampler）
    gal_tex *t = tex ? gal_tex_get(tex) : NULL;
    if ((unsigned)binding >= GS_MAX_TEX) GRED_ONCE("贴图绑定号 %d 超出表长 %d", binding, GS_MAX_TEX);
    else if (t && t->info.target == 9) { if (g_gs.buftex[binding] != tex) { g_gs.buftex[binding] = tex; g_gs.buftex_gen[binding] = ++g_bind_gen; } }
    else {
        if (g_gs.tex[binding] != tex || g_gs.smp[binding] != smp) { g_gs.tex[binding] = tex; g_gs.smp[binding] = smp; g_gs.tex_gen[binding] = ++g_bind_gen; }
        if (!tex && g_gs.buftex[binding]) { g_gs.buftex[binding] = 0; g_gs.buftex_gen[binding] = ++g_bind_gen; }
    }
    DIRTY(GS_ARGS);
}
NXGAL_API void nxgal_set_image(int32_t stage, int32_t binding, uint32_t tex) { GAL_API_LOCK(); gal_uw_write(tex);
    (void)stage;
    // 图像缓冲进另一张表（同 Ryujinx Vulkan SetImage），0 两张都清
    gal_tex *t = tex ? gal_tex_get(tex) : NULL;
    if ((unsigned)binding >= GS_MAX_IMG) GRED_ONCE("图像绑定号 %d 超出表长 %d", binding, GS_MAX_IMG);
    else if (t && t->info.target == 9) { if (g_gs.bufimg[binding] != tex) { g_gs.bufimg[binding] = tex; g_gs.bufimg_gen[binding] = ++g_bind_gen; } }
    else {
        if (g_gs.img[binding] != tex) { g_gs.img[binding] = tex; g_gs.img_gen[binding] = ++g_bind_gen; }
        if (!tex && g_gs.bufimg[binding]) { g_gs.bufimg[binding] = 0; g_gs.bufimg_gen[binding] = ++g_bind_gen; }
    }
    DIRTY(GS_ARGS);
}
NXGAL_API void nxgal_set_texture_array(int32_t stage, int32_t binding, uint32_t arr) { GAL_API_LOCK(); (void)stage; if ((unsigned)binding < GS_MAX_ARR) g_gs.arr[binding] = arr; else GRED_ONCE("贴图数组绑定号 %d 超出表长 %d", binding, GS_MAX_ARR); DIRTY(GS_ARGS); }
NXGAL_API void nxgal_set_texture_array_separate(int32_t stage, int32_t set, uint32_t arr) { GAL_API_LOCK(); (void)stage; if ((unsigned)set < GAL_MAX_SETS) g_gs.arr_set[set] = arr; DIRTY(GS_ARGS); }
NXGAL_API void nxgal_set_transform_feedback_buffers(const nxgal_buf_range *r, int32_t n) { GAL_API_LOCK();
    for (int i = 0; i < n; i++) if (r[i].buf) { GRED_ONCE("变换反馈缓冲未实现（第 8 块；能力表已报不支持）"); break; }   // Gpu 层每次都会设一组空槽，只在真挂了缓冲时才报
}

void gal_state_init(void) {   // 置缺省（只是内存初值，不碰 Metal）；nxgal_init 首次调用（原先是加载时构造函数：可用性标注对构造函数不生效）
    memset(&g_gs, 0, sizeof g_gs);
    for (int i = 0; i < 8; i++) { g_gs.mask[i] = 0xf; g_gs.blend[i].color_op = g_gs.blend[i].alpha_op = 1; g_gs.blend[i].color_src = g_gs.blend[i].alpha_src = 2; g_gs.blend[i].color_dst = g_gs.blend[i].alpha_dst = 1; }
    g_gs.front_face = 0x901; g_gs.cull_face = 0x405; g_gs.topology = 4; g_gs.poly = 0x1b02;
    g_gs.depth.func = 8;
    g_gs.dirty = ~0u;
}

// ---------- 管线缓存 ----------
typedef struct {
    uint64_t prog_hash;
    uint32_t cf[8]; uint32_t samples;
    uint32_t blend[8][7]; uint8_t mask[8];
    uint8_t topo_class, discard, a2c, a2one;
    uint8_t wl, nofrag, lop, pad_;   // wl：宽线展开（顶点函数换 s<键>_wl、三角形拓扑类、自取不带顶点描述符）；nofrag：诊断 NXGAL_NOFRAG_PROG 命中（不带片元函数）；lop：逻辑运算入口（运算号 − 0x1500 + 1，0 = 不用）
    struct { int16_t fmt, buf, offset; uint8_t on, pad; } attr[32];
    struct { uint8_t step; uint8_t pad[3]; uint32_t rate; } vb[16];
    uint32_t key_pad;   // 保留旧键末尾的 4 字节对齐零填充
    uint32_t m3_depth, m3_stencil;   // 仅 Metal 3 进键；Metal 4 仍使用此前的键字节范围
} pso_key;
_Static_assert(offsetof(pso_key, m3_depth) == 672, "Metal 4 管线键布局必须保持 672 字节");
static size_t pso_key_size(void) { return gal_be_kind() == GAL_BE_MTL3 ? sizeof(pso_key) : offsetof(pso_key, m3_depth); }
// color_round_mask：half 附件 RTZ 位图（建表项时按完整管线键算一次）
// lop_addr：逻辑运算参数（S2ALop）在常驻表里的 GPU 地址（键有 lop 时建表项时算一次，0 = 不用 / 表满）
typedef struct { pso_key k; id<MTLRenderPipelineState> p; uint8_t color_round_mask; uint64_t lop_addr; } pso_ent;
static pso_ent *g_pso; static int g_npso, g_cappso;
static uint32_t *g_pso_hash; static int g_pso_hcap;   // 开放寻址表：存下标 + 1

static uint64_t fnv(const void *p, size_t n) { const uint8_t *b = p; uint64_t h = 1469598103934665603ull; while (n--) { h ^= *b++; h *= 1099511628211ull; } return h; }
// 管线键哈希（只用来选桶；建表与查表同一个函数）：按 8 字节一组混合，比逐字节 FNV 少约 7/8 的循环。
//   管线键约 670 字节、换程序时几乎每次绘制都查一次（10-23 原生层线：Mac 塞尔达回放 gal_pso_get 自身占绘制路径约 10%）
static uint64_t key_hash(const void *p, size_t n) {
    const uint8_t *b = p; uint64_t h = 0x9E3779B97F4A7C15ull ^ n, w;
    for (; n >= 8; n -= 8, b += 8) { memcpy(&w, b, 8); h = (h ^ w) * 0xBF58476D1CE4E5B9ull; h ^= h >> 31; }
    for (; n; n--) h = (h ^ *b++) * 0x94D049BB133111EBull;
    return h ^ (h >> 29);
}

// 诊断（原生层线 10-23 塞尔达主几何遍按程序拆片元成本，缺省关、关时只读一个整数）：NXGAL_NOFRAG_PROG=<片元键>[,…]（至多 8 个）命中的程序建不带片元函数的管线
//   （深度 / 模板照写、遮挡关系不变，颜色不写）：遍 GPU 时间的降幅 = 该程序的片元成本。走整条现建（不走基础管线特化）
static int g_nf = -1, g_nfn, g_nfall; static uint64_t g_nfk[8];   // g_nfall：值为 * 时所有带片元的程序都去片元（量整遍片元 / 顶点占比）
static int nofrag_hit(const gal_prog *pg) {
    if (g_nf < 0) { g_nf = 0; const char *v = getenv("NXGAL_NOFRAG_PROG"); if (v && *v == '*') { g_nfall = 1; g_nfn = 1; v = NULL; }
        while (v && *v && g_nfn < 8) { char *e; uint64_t x = strtoull(v, &e, 16); if (e == v) break; g_nfk[g_nfn++] = x; v = *e == ',' ? e + 1 : e; }
        g_nf = g_nfn > 0; if (g_nf) fprintf(stderr, "[gal] 诊断：%d 个片元键改无片元管线（NXGAL_NOFRAG_PROG）\n", g_nfn); }
    if (!g_nf || gal_diag_alt_off()) return 0;
    if (g_nfall) return pg->fn[5] != nil;
    for (int i = 0; i < g_nfn; i++) if (pg->stage_hash[5] == g_nfk[i]) return 1;
    return 0;
}
static int lop_fmt_float_or_srgb(MTLPixelFormat f) {
    switch (f) {
        case MTLPixelFormatR16Float: case MTLPixelFormatRG16Float: case MTLPixelFormatRGBA16Float: case MTLPixelFormatR32Float: case MTLPixelFormatRG32Float:
        case MTLPixelFormatRGBA32Float: case MTLPixelFormatRG11B10Float: case MTLPixelFormatRGB9E5Float: case MTLPixelFormatR8Unorm_sRGB: case MTLPixelFormatRG8Unorm_sRGB:
        case MTLPixelFormatRGBA8Unorm_sRGB: case MTLPixelFormatBGRA8Unorm_sRGB: case MTLPixelFormatBGRA10_XR_sRGB: case MTLPixelFormatBGR10_XR_sRGB: return 1;
        default: return 0;
    }
}
// 逻辑运算的格式类别（S2ALop.kind，gal_logicop.m）：0 其他（不做）1 纯无符号整数 2 纯有符号整数 3 unorm 4 snorm；*bits = 各分量位宽（r | g<<8 | b<<16 | a<<24，着色器分量顺序）
//   是不是纯整数目标以 gal_fmt_is_int 为准（lop_apply 判）；这张表只补它没有的符号与各分量位宽，以及 unorm / snorm 归类（报红写明类别）
static int lop_fmt_kind(MTLPixelFormat f, uint32_t *bits) {
    #define B4(r, g, b, a) ((uint32_t)(r) | (uint32_t)(g) << 8 | (uint32_t)(b) << 16 | (uint32_t)(a) << 24)
    switch (f) {
        case MTLPixelFormatR8Uint: *bits = B4(8, 0, 0, 0); return 1;     case MTLPixelFormatR8Sint: *bits = B4(8, 0, 0, 0); return 2;
        case MTLPixelFormatRG8Uint: *bits = B4(8, 8, 0, 0); return 1;    case MTLPixelFormatRG8Sint: *bits = B4(8, 8, 0, 0); return 2;
        case MTLPixelFormatRGBA8Uint: *bits = B4(8, 8, 8, 8); return 1;  case MTLPixelFormatRGBA8Sint: *bits = B4(8, 8, 8, 8); return 2;
        case MTLPixelFormatR16Uint: *bits = B4(16, 0, 0, 0); return 1;   case MTLPixelFormatR16Sint: *bits = B4(16, 0, 0, 0); return 2;
        case MTLPixelFormatRG16Uint: *bits = B4(16, 16, 0, 0); return 1; case MTLPixelFormatRG16Sint: *bits = B4(16, 16, 0, 0); return 2;
        case MTLPixelFormatRGBA16Uint: *bits = B4(16, 16, 16, 16); return 1; case MTLPixelFormatRGBA16Sint: *bits = B4(16, 16, 16, 16); return 2;
        case MTLPixelFormatR32Uint: *bits = B4(32, 0, 0, 0); return 1;   case MTLPixelFormatR32Sint: *bits = B4(32, 0, 0, 0); return 2;
        case MTLPixelFormatRG32Uint: *bits = B4(32, 32, 0, 0); return 1; case MTLPixelFormatRG32Sint: *bits = B4(32, 32, 0, 0); return 2;
        case MTLPixelFormatRGBA32Uint: *bits = B4(32, 32, 32, 32); return 1; case MTLPixelFormatRGBA32Sint: *bits = B4(32, 32, 32, 32); return 2;
        case MTLPixelFormatRGB10A2Uint: *bits = B4(10, 10, 10, 2); return 1;
        case MTLPixelFormatA8Unorm: *bits = B4(0, 0, 0, 8); return 3;    case MTLPixelFormatR8Unorm: *bits = B4(8, 0, 0, 0); return 3;
        case MTLPixelFormatRG8Unorm: *bits = B4(8, 8, 0, 0); return 3;   case MTLPixelFormatRGBA8Unorm: case MTLPixelFormatBGRA8Unorm: *bits = B4(8, 8, 8, 8); return 3;
        case MTLPixelFormatR16Unorm: *bits = B4(16, 0, 0, 0); return 3;  case MTLPixelFormatRG16Unorm: *bits = B4(16, 16, 0, 0); return 3;
        case MTLPixelFormatRGBA16Unorm: *bits = B4(16, 16, 16, 16); return 3;
        case MTLPixelFormatRGB10A2Unorm: case MTLPixelFormatBGR10A2Unorm: *bits = B4(10, 10, 10, 2); return 3;
        case MTLPixelFormatB5G6R5Unorm: *bits = B4(5, 6, 5, 0); return 3;
        case MTLPixelFormatA1BGR5Unorm: case MTLPixelFormatBGR5A1Unorm: *bits = B4(5, 5, 5, 1); return 3;
        case MTLPixelFormatABGR4Unorm: *bits = B4(4, 4, 4, 4); return 3;
        case MTLPixelFormatR8Snorm: *bits = B4(8, 0, 0, 0); return 4;    case MTLPixelFormatRG8Snorm: *bits = B4(8, 8, 0, 0); return 4;
        case MTLPixelFormatRGBA8Snorm: *bits = B4(8, 8, 8, 8); return 4; case MTLPixelFormatR16Snorm: *bits = B4(16, 0, 0, 0); return 4;
        case MTLPixelFormatRG16Snorm: *bits = B4(16, 16, 0, 0); return 4; case MTLPixelFormatRGBA16Snorm: *bits = B4(16, 16, 16, 16); return 4;
        default: *bits = 0; return 0;
    }
    #undef B4
}
uint64_t g_lop_unimpl_draws;   // 逻辑运算未实现、按复制画、且有非浮点目标被写的管线键次数（单测读）
uint64_t g_lop_emu_keys;       // 逻辑运算走 _lo 入口仿真的管线键次数（单测读）
// 逻辑运算对本次管线键的作用：NOOP 改写掩码 0；纯整数目标且程序有 _lo 入口 → 键记 lop（管线换 _lo）；其余非浮点目标报红（按复制画）
static void lop_apply(pso_key *k, uint32_t hid, const gal_prog *pg) {
    if (!g_lop_en || g_lop_op == 0x1503) return;
    int emu = 0;
    for (int i = 0; i < 8; i++) {
        if (!k->cf[i] || (hid >> i & 1) || !k->mask[i] || lop_fmt_float_or_srgb((MTLPixelFormat)k->cf[i])) continue;
        if (g_lop_op == 0x1505) { k->mask[i] = 0; continue; }
        uint32_t bits; int kind = lop_fmt_kind((MTLPixelFormat)k->cf[i], &bits), is_int = gal_fmt_is_int((MTLPixelFormat)k->cf[i]);
        int out_int = (pg->fs_outputs >> i & 1) && pg->fs_output_ctype[i] != 0;
        if (is_int && (kind == 1 || kind == 2) && pg->fn_lo && out_int && g_lop_op >= 0x1500 && g_lop_op <= 0x150f) { emu = 1; continue; }
        g_lop_unimpl_draws++;
        // 每种（运算, 格式）各报一次，不半静默（10-24 总指挥）：已报过的组合记在小表里
        static uint32_t seen[64]; static int nseen; uint32_t sig = (uint32_t)(g_lop_op & 0xffff) << 16 | (k->cf[i] & 0xffff); int dup = 0;
        for (int j = 0; j < nseen; j++) dup |= seen[j] == sig;
        const char *why = is_int && kind != 1 && kind != 2 ? "纯整数，但位宽表没有这个格式" : kind == 3 ? "unorm（归一化整数，要按存储位模式做，未做）" : kind == 4 ? "snorm（有符号归一化整数，未做）"
                        : (kind == 1 || kind == 2) && !out_int ? "纯整数，但片元没有整数输出写它" : kind == 1 || kind == 2 ? "纯整数，但程序没有逻辑运算入口 _lo" : "未归类";
        if (!dup) { if (nseen < 64) seen[nseen++] = sig; GLOG("【红】逻辑运算 %#x 未实现（第 8 块）：目标 %d 是非浮点格式 %d，类别 %s，结果与复制不同，按复制画（此组合首例）", g_lop_op, i, k->cf[i], why); }
    }
    // 11-01 审计 P1-21（需读数再定，语义不改）：_lo 入口读附件 [[color(i)]] 没标光栅顺序组，同一遍内重叠片元的结果依赖完成顺序；首例点名，次数看 g_lop_emu_keys
    if (emu) { k->lop = (uint8_t)(g_lop_op - 0x1500 + 1); g_lop_emu_keys++; GRED_ONCE("逻辑运算 %#x 走 _lo 入口仿真（帧缓冲读取，无光栅顺序组：同一遍内重叠片元结果依赖完成顺序，审计 P1-21 待读数），首例程序 %016llx", g_lop_op, (unsigned long long)pg->hash); }
}
// 逻辑运算参数常驻表（gal_logicop.m 的 S2ALop：运算号 + 每目标类别 / 位宽，68 字节，按 128 字节一项）：内容只由（运算号, 颜色格式）定，表项只增不改，
//   GPU 按地址读不必同步；同内容复用一项。表满（4096 种组合，不现实）报红、该管线不画
typedef struct { uint32_t op, kind[8], bits[8]; } lop_ent;
#define LOP_STRIDE 128
#define LOP_CAP 4096
static id<MTLBuffer> g_lop_buf; static lop_ent *g_lop_tab; static int g_nlop;
static uint64_t lop_addr_of(const pso_key *k) {
    if (!k->lop) return 0;
    lop_ent e; memset(&e, 0, sizeof e); e.op = (uint32_t)(k->lop - 1);
    for (int i = 0; i < 8; i++) {
        uint32_t bits; int kind = k->cf[i] && k->mask[i] && gal_fmt_is_int((MTLPixelFormat)k->cf[i]) ? lop_fmt_kind((MTLPixelFormat)k->cf[i], &bits) : 0;
        if (kind == 1 || kind == 2) { e.kind[i] = (uint32_t)kind; e.bits[i] = bits; }   // unorm / snorm 不在 _lo 里做（已报红），按 0 原样
    }
    for (int j = 0; j < g_nlop; j++) if (!memcmp(&g_lop_tab[j], &e, sizeof e)) return g_lop_buf.gpuAddress + (uint64_t)j * LOP_STRIDE;
    if (!g_lop_buf) {
        g_lop_buf = [g_gdev newBufferWithLength:LOP_STRIDE * LOP_CAP options:MTLResourceStorageModeShared];
        if (!g_lop_buf) { GRED_ONCE("建逻辑运算参数表失败：%s", gal_mem_note()); return 0; }
        gal_res_add(g_lop_buf); g_lop_tab = calloc(LOP_CAP, sizeof *g_lop_tab);
    }
    if (g_nlop == LOP_CAP) { GRED_ONCE("逻辑运算参数表满（%d 种组合），新组合的管线不画", LOP_CAP); return 0; }
    memcpy((uint8_t *)g_lop_buf.contents + (size_t)g_nlop * LOP_STRIDE, &e, sizeof e); g_lop_tab[g_nlop] = e;
    return g_lop_buf.gpuAddress + (uint64_t)(g_nlop++) * LOP_STRIDE;
}
static int pso_key_build(pso_key *k, const gal_prog *pg) {
    memset(k, 0, sizeof *k);
    k->prog_hash = pg->hash;
    gal_pass_formats(k->cf, &k->samples);
    if (gal_be_kind() == GAL_BE_MTL3) gal_pass_ds_formats(&k->m3_depth, &k->m3_stencil);
    // 两遍合一的隐藏颜色槽：格式照物理附件，写掩码 0、不混合（键里 blend / mask 留 0）
    uint32_t hid = gal_pass_hidden_mask();
    for (int i = 0; i < 8; i++) {
        if (!k->cf[i] || (hid >> i & 1)) continue;
        const nxgal_blend *b = &g_gs.blend[i];
        if (b->enable && gal_fmt_is_int((MTLPixelFormat)k->cf[i])) g_int_noblend++;
        else if (b->enable) { k->blend[i][0] = 1; k->blend[i][1] = b->color_op; k->blend[i][2] = b->color_src; k->blend[i][3] = b->color_dst; k->blend[i][4] = b->alpha_op; k->blend[i][5] = b->alpha_src; k->blend[i][6] = b->alpha_dst; }
        k->mask[i] = (uint8_t)g_gs.mask[i];
    }
    lop_apply(k, hid, pg);
    k->topo_class = (uint8_t)topo_class(g_gs.topology); k->discard = (uint8_t)!!g_gs.discard; k->a2c = (uint8_t)!!g_gs.a2c; k->a2one = (uint8_t)!!g_gs.a2one;
    // 0 号目标是整数格式时 alpha-to-coverage / alpha-to-one 关掉（10-24 格式能力普查：校验层下 19 种整数格式两项都断言；整数输出没有 alpha 可言，Vulkan 下也不生效）
    if (k->cf[0] && gal_fmt_is_int((MTLPixelFormat)k->cf[0]) && (k->a2c || k->a2one)) { g_int_noblend++; k->a2c = k->a2one = 0; }
    k->nofrag = (uint8_t)nofrag_hit(pg);
    // 曲面程序：画的是细分展开后的点 / 线 / 三角形（gal_tess.m），拓扑类按 TES 的域与点模式；顶点阶段在计算核里，管线不带顶点描述符
    if (pg->is_tess) { k->topo_class = (uint8_t)(pg->tess_point ? MTLPrimitiveTopologyClassPoint : pg->tess_dom == GAL_TESS_ISO ? MTLPrimitiveTopologyClassLine : MTLPrimitiveTopologyClassTriangle); return 1; }
    if (g_draw_wl && pg->fn_wl) { k->wl = 1; k->topo_class = (uint8_t)MTLPrimitiveTopologyClassTriangle; return 1; }   // 宽线：s<键>_wl 自己取属性
    if (pg->vs_pulled) return 1;   // 顶点自取：管线不带顶点描述符，顶点布局不进键（绘制时绑取数表，gal_draw.m）
    for (int i = 0; i < g_gs.nattr && i < 32; i++) {
        if (!(pg->vs_inputs >> i & 1)) continue;   // 着色器不读的属性不进描述符（也不进键）
        const nxgal_vattr *a = &g_gs.attr[i];
        k->attr[i].on = 1; k->attr[i].fmt = (int16_t)a->format; k->attr[i].buf = (int16_t)(a->is_zero ? -1 : a->buffer); k->attr[i].offset = (int16_t)(a->is_zero ? 0 : a->offset);
        if (!a->is_zero && (unsigned)a->buffer < 16) { const nxgal_vbuf *v = &g_gs.vb[a->buffer]; k->vb[a->buffer].step = v->divisor ? 2 : v->stride ? 1 : 0; k->vb[a->buffer].rate = (uint32_t)v->divisor; }
    }
    // 着色器读但 GAL 没给的属性：按零属性处理（同 Vulkan 后端：未设置的属性读 0）
    for (int i = 0; i < 32; i++) if ((pg->vs_inputs >> i & 1) && !k->attr[i].on) { k->attr[i].on = 1; k->attr[i].fmt = 45; k->attr[i].buf = -1; }
    return 1;
}

// 只在新管线表项建立时计算；混合与 alpha-to-coverage 必须使用原始源颜色。
static uint8_t pso_color_round_mask(const pso_key *k, const gal_prog *pg) {
    if (!pg->fs_color_round || k->a2c || k->discard) return 0;
    uint8_t mask = 0;
    for (int i = 0; i < 8; i++) {
        if (!(pg->fs_outputs >> i & 1) || pg->fs_output_ctype[i] != 0 || k->blend[i][0] || !k->mask[i]) continue;
        MTLPixelFormat f = (MTLPixelFormat)k->cf[i];
        if (f == MTLPixelFormatR16Float || f == MTLPixelFormatRG16Float || f == MTLPixelFormatRGBA16Float) mask |= 1u << i;
    }
    return mask;
}

// unspec：片元输出（颜色格式 / 混合 / 写掩码）留空——基础管线（第 2 步：首遇只特化，不完整编译；见 gal_be.h「管线特化」）
// 颜色附件的格式 / 写掩码 / 混合按管线键填（pso_desc4 与通用特化预热共用）
static void pso_desc_colors(MTL4RenderPipelineDescriptor *d, const pso_key *k) {
    for (int i = 0; i < 8; i++) {
        if (!k->cf[i]) continue;
        MTL4RenderPipelineColorAttachmentDescriptor *c = d.colorAttachments[i];
        c.pixelFormat = (MTLPixelFormat)k->cf[i];
        uint8_t m = k->discard ? 0 : k->mask[i];
        // RGB9E5Float 只许写掩码全开或全关（10-24 格式能力普查：部分通道断言）：部分写按全写，首例报红
        if (c.pixelFormat == MTLPixelFormatRGB9E5Float && m && m != 0xf) { GRED_ONCE("颜色目标 %d 是 RGB9E5Float，部分通道写掩码 %#x 按全写（Metal 不支持）", i, m); m = 0xf; }
        c.writeMask = (m & 1 ? MTLColorWriteMaskRed : 0) | (m & 2 ? MTLColorWriteMaskGreen : 0) | (m & 4 ? MTLColorWriteMaskBlue : 0) | (m & 8 ? MTLColorWriteMaskAlpha : 0);
        if (k->blend[i][0] && !gal_fmt_is_int((MTLPixelFormat)k->cf[i])) {
            c.blendingState = MTL4BlendStateEnabled;
            c.rgbBlendOperation = bop(k->blend[i][1]); c.sourceRGBBlendFactor = bfac(k->blend[i][2]); c.destinationRGBBlendFactor = bfac(k->blend[i][3]);
            c.alphaBlendOperation = bop(k->blend[i][4]); c.sourceAlphaBlendFactor = bfac(k->blend[i][5]); c.destinationAlphaBlendFactor = bfac(k->blend[i][6]);
        } else c.blendingState = MTL4BlendStateDisabled;
    }
}
// Metal 3 的颜色附件：字段与 Metal 4 逐条对应，只有混合开关不同（Metal 4 是 MTL4BlendStateEnabled 枚举，老类是 BOOL blendingEnabled）
static void pso_desc_colors3(MTLRenderPipelineDescriptor *d, const pso_key *k) {
    for (int i = 0; i < 8; i++) {
        if (!k->cf[i]) continue;
        MTLRenderPipelineColorAttachmentDescriptor *c = d.colorAttachments[i];
        c.pixelFormat = (MTLPixelFormat)k->cf[i];
        uint8_t m = k->discard ? 0 : k->mask[i];
        if (c.pixelFormat == MTLPixelFormatRGB9E5Float && m && m != 0xf) { GRED_ONCE("颜色目标 %d 是 RGB9E5Float，部分通道写掩码 %#x 按全写（Metal 不支持）", i, m); m = 0xf; }
        c.writeMask = (m & 1 ? MTLColorWriteMaskRed : 0) | (m & 2 ? MTLColorWriteMaskGreen : 0) | (m & 4 ? MTLColorWriteMaskBlue : 0) | (m & 8 ? MTLColorWriteMaskAlpha : 0);
        if (k->blend[i][0] && !gal_fmt_is_int((MTLPixelFormat)k->cf[i])) {
            c.blendingEnabled = YES;
            c.rgbBlendOperation = bop(k->blend[i][1]); c.sourceRGBBlendFactor = bfac(k->blend[i][2]); c.destinationRGBBlendFactor = bfac(k->blend[i][3]);
            c.alphaBlendOperation = bop(k->blend[i][4]); c.sourceAlphaBlendFactor = bfac(k->blend[i][5]); c.destinationAlphaBlendFactor = bfac(k->blend[i][6]);
        } else c.blendingEnabled = NO;
    }
}
// 顶点 / 片元函数与拓扑类：两套描述共用同一套规则（各写一份迟早走偏）。规则见 pso_desc4
static void pso_fns(const pso_key *k, const gal_prog *pg, int unspec, id *vf, id *ff, MTLPrimitiveTopologyClass *topo) {
    *vf = pg->is_tess ? pg->fn[3] : pg->fn[1];   // 曲面程序：TES 改写的顶点函数
    *ff = k->discard || k->nofrag ? nil : k->lop ? pg->fn_lo : pg->fn[5];   // lop：逻辑运算入口（gal_logicop.m）
    // 顶点着色器写点大小时，Metal 只接受 Point / Unspecified 拓扑类（10-18 动森真局 6 个程序因此建管线失败，psz 探针实测）
    *topo = pg->vs_point_size && k->topo_class != MTLPrimitiveTopologyClassPoint ? MTLPrimitiveTopologyClassUnspecified : (MTLPrimitiveTopologyClass)k->topo_class;
    if (unspec && !pg->vs_writes_layer) *topo = MTLPrimitiveTopologyClassUnspecified;   // 基础管线：拓扑未指定（写层号的必须指定），与出包脚本（shbake/pso_gen.py）逐字段相同才能按描述命中归档
    // 写层号的顶点着色器：拓扑类别必须指定（不能 Unspecified）；它若还写点大小，画线 / 三角形改用无点大小变体（gal_prog.m xc_shader）
    if (pg->vs_layer_np && k->topo_class != MTLPrimitiveTopologyClassPoint) { *vf = pg->fn_np; *topo = (MTLPrimitiveTopologyClass)k->topo_class; }
    if (k->wl) *vf = pg->fn_wl;   // 宽线展开入口（gal_wline.m）：拓扑类同上按键（三角形；写点大小的照规则 Unspecified）
}
// 顶点描述符（MTLVertexDescriptor 两边同一个类）：顶点自取 / 曲面 / 宽线 / 不读属性的不带
static MTLVertexDescriptor *pso_vertex_desc(const pso_key *k, const gal_prog *pg) {
    if (!(pg->vs_inputs && !pg->vs_pulled && !pg->is_tess && !k->wl)) return nil;
    MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
    int zero_used = 0; uint32_t used = 0;   // used：真被属性引用的 GAL 缓冲（格式无效改走零属性的不算，否则给无人引用的槽设布局，Metal 断言——10-18 动森真局第 120 帧崩溃）
    for (int i = 0; i < 32; i++) {
        if (!k->attr[i].on) continue;
        MTLVertexFormat f = vfmt(k->attr[i].fmt);
        if (f == MTLVertexFormatInvalid) { GLOG("【红】顶点属性 %d 格式 %d 无 Metal 顶点格式，按 float4 零值", i, k->attr[i].fmt); f = MTLVertexFormatFloat4; }
        int zero = k->attr[i].buf < 0 || (f == MTLVertexFormatFloat4 && vfmt(k->attr[i].fmt) == MTLVertexFormatInvalid);
        // 着色器按整数读而格式是浮点 / 归一化（或反之）时 Metal 拒绝建管线：零属性按着色器类型取同宽整数格式
        if (zero) { int ct = pg->vs_input_ctype[i]; f = ct == 1 ? MTLVertexFormatUInt4 : ct == 2 ? MTLVertexFormatInt4 : MTLVertexFormatFloat4; }
        vd.attributes[i].format = f;
        vd.attributes[i].offset = zero ? 0 : (NSUInteger)k->attr[i].offset;
        vd.attributes[i].bufferIndex = zero ? GAL_ZERO_VB : GAL_VB_BASE + k->attr[i].buf;
        zero_used |= zero; if (!zero) used |= 1u << k->attr[i].buf;
    }
    for (int b = 0; b < 16; b++) {
        if (!(used >> b & 1)) continue;   // 没有属性引用的缓冲槽不设布局（Metal 校验要求）
        MTLVertexBufferLayoutDescriptor *l = vd.layouts[GAL_VB_BASE + b];
        l.stride = MTLBufferLayoutStrideDynamic;
        if (k->vb[b].step == 2) { l.stepFunction = MTLVertexStepFunctionPerInstance; l.stepRate = k->vb[b].rate; }
        else if (k->vb[b].step == 0) { l.stepFunction = MTLVertexStepFunctionConstant; l.stepRate = 0; }
        else { l.stepFunction = MTLVertexStepFunctionPerVertex; l.stepRate = 1; }
    }
    if (zero_used) { vd.layouts[GAL_ZERO_VB].stride = 16; vd.layouts[GAL_ZERO_VB].stepFunction = MTLVertexStepFunctionConstant; vd.layouts[GAL_ZERO_VB].stepRate = 0; }
    return vd;
}
// Metal 4 管线描述（主路径）：逐字段与改造前相同，产物不变
static MTL4RenderPipelineDescriptor *pso_desc4(const pso_key *k, const gal_prog *pg, int unspec) {
    MTL4RenderPipelineDescriptor *d = [MTL4RenderPipelineDescriptor new];
    id vf, ff; MTLPrimitiveTopologyClass topo; pso_fns(k, pg, unspec, &vf, &ff, &topo);
    d.vertexFunctionDescriptor = vf; d.fragmentFunctionDescriptor = ff;
    // 光栅化丢弃（10-24 异度神剑3）：Metal 关光栅化要求顶点函数返回 void，翻译出的顶点函数都返回结构体，关了就建不出管线。
    //   改为照开光栅化、不带片元函数、颜色写掩码全 0（pso_desc_colors），绘制时剪裁全部置空（gal_state_apply_dynamic）：
    //   顶点照跑（存储写等副作用保留），不出片元，颜色 / 深度 / 模板 / 遮挡计数都不动，与丢弃语义一致。单测 tests/t_rdiscard
    d.rasterizationEnabled = YES;
    d.rasterSampleCount = k->samples ? k->samples : 1;
    d.inputPrimitiveTopology = topo;
    d.alphaToCoverageState = k->a2c ? MTL4AlphaToCoverageStateEnabled : MTL4AlphaToCoverageStateDisabled;
    d.alphaToOneState = k->a2one ? MTL4AlphaToOneStateEnabled : MTL4AlphaToOneStateDisabled;
    for (int i = 0; i < 8 && unspec; i++) gal_pso_unspecialize_color(d, i);
    if (!unspec) pso_desc_colors(d, k);
    MTLVertexDescriptor *vd = pso_vertex_desc(k, pg); if (vd) d.vertexDescriptor = vd;
    return d;
}
// Metal 3 的函数描述 → MTLFunction。程序里存的是「库 + 函数名」（Metal 4 形态），老接口要函数对象；只在建描述时取一次，
//   不另建缓存：管线建成后描述用完即弃，缓存反而会把已经放掉的库一直留住
static id<MTLFunction> pso_fn3(id fd) {
    if (!fd) return nil;
    if (![fd respondsToSelector:@selector(library)] || ![fd respondsToSelector:@selector(name)]) { GRED_ONCE("Metal 3：管线函数不是「库 + 函数名」描述（%s），建不了", class_getName([fd class])); return nil; }
    id lib = [fd valueForKey:@"library"]; NSString *nm = [fd valueForKey:@"name"];
    if (!lib || !nm.length) { GRED_ONCE("Metal 3：函数描述缺库或函数名，管线建不出"); return nil; }
    id<MTLFunction> f = [lib newFunctionWithName:nm];
    if (!f) GRED_ONCE("Metal 3：库里取不到函数 %s，管线建不出", nm.UTF8String);
    return f;
}
// Metal 3 管线描述（gal_be.h「管线与归档」Metal 3 列）：MTLRenderPipelineDescriptor，函数按名直接取。
//   没有「片元输出留空的基础管线」这一层（26 才有特化接口）：unspec 请求返回空，预取用表的 b 行按「归档没有」处理，不建半条管线
static MTLRenderPipelineDescriptor *pso_desc3(const pso_key *k, const gal_prog *pg, int unspec) {
    if (unspec) return nil;
    id vr, fr; MTLPrimitiveTopologyClass topo; pso_fns(k, pg, unspec, &vr, &fr, &topo);
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = pso_fn3(vr);
    if (!d.vertexFunction) { static int n; if (n++ < 8) GLOG("【红】Metal 3：程序 %016llx 取不到顶点函数，管线建不出", (unsigned long long)pg->hash); return nil; }
    if (fr) { d.fragmentFunction = pso_fn3(fr); if (!d.fragmentFunction) { static int n; if (n++ < 8) GLOG("【红】Metal 3：程序 %016llx 取不到片元函数，管线建不出", (unsigned long long)pg->hash); return nil; } }
    d.rasterizationEnabled = YES;   // 光栅化丢弃同 Metal 4：照开、不带片元、写掩码 0（见 pso_desc4 注释）
    d.rasterSampleCount = k->samples ? k->samples : 1;
    d.inputPrimitiveTopology = topo;
    d.alphaToCoverageEnabled = k->a2c != 0;
    d.alphaToOneEnabled = k->a2one != 0;
    d.depthAttachmentPixelFormat = (MTLPixelFormat)k->m3_depth;
    d.stencilAttachmentPixelFormat = (MTLPixelFormat)k->m3_stencil;
    pso_desc_colors3(d, k);
    d.vertexDescriptor = pso_vertex_desc(k, pg);
    return d;
}
// 管线描述：Metal 4 出 MTL4RenderPipelineDescriptor（主路径），Metal 3 出 MTLRenderPipelineDescriptor（老接口）
static id pso_desc(const pso_key *k, const gal_prog *pg, int unspec) {
    return gal_be_kind() == GAL_BE_MTL3 ? (id)pso_desc3(k, pg, unspec) : (id)pso_desc4(k, pg, unspec);
}

// 基础管线表：键 = 管线键去掉片元输出（颜色格式 / 混合 / 写掩码），值 = 片元输出留空编出的管线；只光栅化丢弃（discard）的不走这里
// job：异步现建中（首局根治 B），编完转成 p
typedef struct { pso_key k; id<MTLRenderPipelineState> p; gal_pso_job *job; } pso_base_ent;
static pso_base_ent *g_pbase; static int g_npbase, g_cappbase;
static void pso_key_base(pso_key *b, const pso_key *k, const gal_prog *pg) {
    *b = *k; memset(b->cf, 0, sizeof b->cf); memset(b->blend, 0, sizeof b->blend); memset(b->mask, 0, sizeof b->mask);
    if (!pg->vs_writes_layer) b->topo_class = 0;   // 基础管线拓扑未指定：拓扑不进基础键（写层号的必须指定拓扑，保留）
}

static int g_pso_pend;   // 本次 gal_pso_get 因基础管线异步现建中返回空（首局根治 B）
int gal_pso_pending(void) { return g_pso_pend; }
// 首遇特化改由设备归档按完整描述直接取到的次数（gal_core.m 设备归档）
static uint64_t g_spec_dev_hit, g_spec_pack_hit;
uint64_t gal_spec_dev_hits(void) { return g_spec_dev_hit; }
uint64_t gal_spec_pack_hits(void) { return g_spec_pack_hit; }
// ---------- 管线预取（10-22 换场景首帧建管线：马车8 进赛道那帧 145 条全是归档命中、散在 79 片里，开片 42 ms + 取 49 ms 全落在渲染线程）----------
// 用表 = 包里 shaders/pso_use.tsv（出包 shbake/psouse.py 从各正式局「管线首用」行收，按首用帧升序；pso_gen.py 按它把这些管线排进最前面几片，同局先后用到的挨着放）。
//   每行「<首用帧> <b|f> <函数名串> <管线键编码>」：b = 基础管线键（pso_key_base 之后、片元输出留空），f = 完整管线键。
// 程序建成（load_binary / 首遇现编收尾）时按程序哈希挑出表里它的行，当场（持 API 锁、程序在）用渲染线程同一个 pso_desc 造描述，交后台串行队列只查归档（包 + 设备，开片照记低区账）；
//   取到的进预取池（键 = 管线键字节 + b/f），渲染线程 pso_build 首遇先查池、取走即删。同函数、同键、同程序造的描述逐字段相同，池里的就是渲染线程自己会从归档取到的那条；
//   表旧了（键布局 / 语义变了）只会取不到或池里没人要，不会给错管线。池里剩的 = 本局没用到的（读数报出）
typedef struct { pso_key k; uint8_t base; } pf_line;
static pf_line *g_pf; static int g_npf, g_pf_bad;
static NSMutableDictionary<NSNumber *, NSMutableArray<NSNumber *> *> *g_pf_byprog;   // 程序哈希 → 表行下标（每个程序只排一次、排过即删；API 锁下读写）
static NSMutableDictionary<NSData *, id> *g_pf_pool; static os_unfair_lock g_pf_mu = OS_UNFAIR_LOCK_INIT;
static dispatch_queue_t g_pf_q;
static _Atomic uint64_t g_pf_st[5]; static _Atomic int64_t g_pf_inq;   // 0 已排 1 取到 2 归档没有 3 渲染线程取用 4 后台用时（ns）；在排条数
static NSData *pf_kd(const pso_key *k, int base) { NSMutableData *d = [NSMutableData dataWithBytes:k length:pso_key_size()]; uint8_t b = (uint8_t)base; [d appendBytes:&b length:1]; return d; }
// 管线键编码：逐字节两位十六进制，连续 n 个（2–255）零字节写成「-」+ 两位十六进制 n（顶点自取的程序顶点布局全零，672 字节的键编出来几十个字符）；psouse.py 原样搬、不解码
static NSString *pf_enc(const pso_key *k) {
    const uint8_t *b = (const uint8_t *)k; NSMutableString *s = [NSMutableString string];
    for (size_t i = 0; i < pso_key_size();) {
        size_t n = 0; while (i + n < pso_key_size() && !b[i + n] && n < 255) n++;
        if (n >= 2) { [s appendFormat:@"-%02zx", n]; i += n; } else { [s appendFormat:@"%02x", b[i]]; i++; }
    }
    return s;
}
static int pf_hx(char c) { return c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : -1; }
static int pf_dec(const char *s, pso_key *k) {
    memset(k, 0, sizeof *k);
    uint8_t *b = (uint8_t *)k; size_t o = 0;
    while (*s && *s != '\t' && *s != '\n' && *s != '\r' && *s != ' ') {
        int z = *s == '-'; if (z) s++;
        int h = pf_hx(s[0]), l = h < 0 ? -1 : pf_hx(s[1]); if (l < 0) return 0;
        unsigned v = (unsigned)(h * 16 + l); s += 2;
        if (z) { if (o + v > pso_key_size()) return 0; memset(b + o, 0, v); o += v; }
        else { if (o >= pso_key_size()) return 0; b[o++] = (uint8_t)v; }
    }
    return o == pso_key_size();
}
// 「管线首用」行：渲染线程上每条管线首次建成 / 取到（任何来源）记一行，本进程同一条只记一次；只记游戏程序（函数名 s<16 位十六进制>[_后缀]），内部预建期间不记
static void pf_note(const pso_key *k, int base, id d) {
    if (gal_pso_warming()) return;
    static NSMutableSet<NSData *> *seen; NSData *kd = pf_kd(k, base);
    if (!seen) seen = [NSMutableSet set];
    if ([seen containsObject:kd]) return;
    [seen addObject:kd];
    NSString *pn = gal_pso_pname(d);
    if (pn.length < 17 || [pn characterAtIndex:0] != 's' || (pn.length > 17 && [pn characterAtIndex:17] != ',' && [pn characterAtIndex:17] != '_')) return;
    GLOG("管线首用 v1 %zu %llu %c %s %s", pso_key_size(), (unsigned long long)gal_present_count(), base ? 'b' : 'f', pn.UTF8String, pf_enc(k).UTF8String);
}
static uint64_t pf_footprint(void) { task_vm_info_data_t v; mach_msg_type_number_t n = TASK_VM_INFO_COUNT; return task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&v, &n) == KERN_SUCCESS ? v.phys_footprint : 0; }
void gal_pso_pf_prog(const gal_prog *pg) {
    if (!g_npf || !pg) return;
    NSNumber *ph = @(pg->hash); NSArray<NSNumber *> *ix = g_pf_byprog[ph]; if (!ix) return;
    [g_pf_byprog removeObjectForKey:ph];
    static uint64_t f0; if (!f0) f0 = pf_footprint();
    for (NSNumber *n in ix) @autoreleasepool {
        const pf_line *l = &g_pf[n.intValue];
        id d = pso_desc(&l->k, pg, l->base); NSData *kd = pf_kd(&l->k, l->base);
        g_pf_st[0]++; g_pf_inq++;
        dispatch_async(g_pf_q, ^{ @autoreleasepool {
            uint64_t t0 = mach_absolute_time(); id p = gal_pso_arch_lookup(d);
            g_pf_st[4] += mach_absolute_time() - t0;
            if (p) { g_pf_st[1]++; os_unfair_lock_lock(&g_pf_mu); g_pf_pool[kd] = p; os_unfair_lock_unlock(&g_pf_mu); } else g_pf_st[2]++;
            // 排空（程序成批载完一波）：第 1、2、4… 次打一行；内存差含同期别的分配（开机载程序 / 贴图），只当上界参考
            if (--g_pf_inq == 0) { static uint64_t nd; uint64_t m = ++nd; if (!(m & (m - 1))) { static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb);
                GLOG("管线预取排空（第 %llu 次）：已排 %llu、取到 %llu、归档没有 %llu，后台用时 %.0f ms，首次排起到现在进程内存 %+.1f MB（含同期别的分配，上界）", (unsigned long long)m,
                     (unsigned long long)g_pf_st[0], (unsigned long long)g_pf_st[1], (unsigned long long)g_pf_st[2], (double)g_pf_st[4] * tb.numer / tb.denom / 1e6, ((double)pf_footprint() - (double)f0) / 1048576.0); } }
        } });
    }
}
void gal_pso_pf_load(const char *path) {
    FILE *f = fopen(path, "r"); if (!f) return;
    char *ln = NULL; size_t cap = 0; int bad = 0, capn = 0;
    free(g_pf); g_pf = NULL; g_npf = 0; g_pf_byprog = [NSMutableDictionary dictionary];
    while (getline(&ln, &cap, f) > 0) {
        if (ln[0] == '#') continue;
        // <首用帧>\t<b|f>\t<函数名串>\t<管线键编码>
        char *c1 = strchr(ln, '\t'), *c2 = c1 ? strchr(c1 + 1, '\t') : NULL, *c3 = c2 ? strchr(c2 + 1, '\t') : NULL;
        pso_key k;
        if (!c3 || (c1[1] != 'b' && c1[1] != 'f') || !pf_dec(c3 + 1, &k)) { bad++; continue; }
        if (g_npf == capn) { capn = capn ? capn * 2 : 1024; g_pf = realloc(g_pf, (size_t)capn * sizeof *g_pf); }
        g_pf[g_npf].k = k; g_pf[g_npf].base = c1[1] == 'b';
        NSNumber *ph = @(k.prog_hash); NSMutableArray *a = g_pf_byprog[ph]; if (!a) g_pf_byprog[ph] = a = [NSMutableArray array];
        [a addObject:@(g_npf)]; g_npf++;
    }
    free(ln); fclose(f); g_pf_bad = bad;
    if (!g_pf_pool) g_pf_pool = [NSMutableDictionary dictionary];
    if (!g_pf_q) g_pf_q = dispatch_queue_create("s2a.pso.prefetch", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
    GLOG("%s管线预取用表：%d 条、%lu 个程序，坏行 %d（跳过）", bad ? "【红】" : "", g_npf, (unsigned long)g_pf_byprog.count, bad);
    // 表载入前已建成的程序（Ryujinx 磁盘缓存可能先于归档登记载完）补排
    for (uint32_t i = 1; i < gal_prog_slots(); i++) { const gal_prog *pg = gal_prog_get(i); if (pg && !pg->status) gal_pso_pf_prog(pg); }
}
static id<MTLRenderPipelineState> pso_pf_take(const pso_key *k, int base) {
    if (!g_npf) return nil;
    NSData *kd = pf_kd(k, base);
    os_unfair_lock_lock(&g_pf_mu); id p = g_pf_pool[kd]; if (p) [g_pf_pool removeObjectForKey:kd]; os_unfair_lock_unlock(&g_pf_mu);
    if (p) g_pf_st[3]++;
    return p;
}
void gal_pso_pf_stats(uint64_t out[7]) { for (int i = 0; i < 5; i++) out[i] = g_pf_st[i]; out[5] = (uint64_t)g_npf; out[6] = (uint64_t)g_pf_bad; }
void gal_pso_pf_report(void) {
    if (!g_npf) return;
    os_unfair_lock_lock(&g_pf_mu); NSUInteger left = g_pf_pool.count; os_unfair_lock_unlock(&g_pf_mu);
    static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb);
    GLOG("管线预取读数：用表 %d 条，已排 %llu、取到 %llu、归档没有 %llu、渲染线程取用 %llu、池里剩 %lu，后台用时 %.0f ms", g_npf, (unsigned long long)g_pf_st[0], (unsigned long long)g_pf_st[1],
         (unsigned long long)g_pf_st[2], (unsigned long long)g_pf_st[3], (unsigned long)left, (double)g_pf_st[4] * tb.numer / tb.denom / 1e6);
}
// 基础管线的异步任务编完（跳绘制模式 NXGAL_PSO_ASYNC）：转成 p
static void pso_base_poll(int bi) {
    pso_base_ent *be = &g_pbase[bi];
    if (!be->job) return;
    int done; id<MTLRenderPipelineState> q = gal_pso_job_take(be->job, &done);
    if (!done) return;
    be->job = NULL; be->p = q;
}
static id<MTLRenderPipelineState> pso_build(const pso_key *k, const gal_prog *pg) {
    GP_SCOPE(GP_PSO_BUILD);
    NSError *e = nil; id<MTLRenderPipelineState> p = nil;
    // 逻辑运算入口（k->lop）首版走整条现建：片元函数是 _lo，不进基础管线特化（键对不上出包的基础管线）
    if (!k->discard && !k->nofrag && !k->lop && gal_pso_can_specialize()) {
        // 两级：基础管线（片元输出留空，同程序 / 同顶点布局只编一次）→ 按本次颜色格式 / 混合特化（实测中位 0.00 ms，psobench）。
        //   只有顶点阶段的程序（无片元、光栅化开：深度预渲染 / 阴影一类）同样走这条：10-21 探针实测片元为空 + 颜色留空的基础管线能建、能特化、校验层下照画；
        //   原先它们带着本次颜色格式整条现建、永远对不上出包归档（怪猎首局 39 条「片元 -」现建），出包 pso_gen.py 同样给它们出基础管线
        // 基础管线首遇（归档没命中）：阻塞现建；NXGAL_PSO_ASYNC=1 是跳绘制模式（缺省关）
        pso_key b; pso_key_base(&b, k, pg); int bi = -1;
        for (int i = 0; i < g_npbase && bi < 0; i++) if (!memcmp(&g_pbase[i].k, &b, pso_key_size())) bi = i;
        if (bi >= 0) { pso_base_poll(bi); if (g_pbase[bi].job) { g_pso_pend = 1; return nil; } }
        if (bi < 0) {
            id<MTLRenderPipelineState> base = nil; gal_pso_job *job = NULL;
            // 预取池有（后台按用表从归档取好的）：当归档命中用，不在渲染线程上开片 / 取
            if ((base = pso_pf_take(&b, 1))) {}
            else if (gal_pso_async_on()) job = gal_new_render_pso_async(pso_desc(&b, pg, 1), &base);
            else base = gal_new_render_pso(pso_desc(&b, pg, 1), &e);
            if (!base && !job) { static int n; if (n++ < 8) GLOG("【红】基础管线编译失败（程序 %016llx）：%s", (unsigned long long)pg->hash, e.localizedDescription.UTF8String); return nil; }
            if (g_npbase == g_cappbase) { g_cappbase = g_cappbase ? g_cappbase * 2 : 256; g_pbase = realloc(g_pbase, g_cappbase * sizeof *g_pbase); memset((void *)(g_pbase + g_npbase), 0, (g_cappbase - g_npbase) * sizeof *g_pbase); }
            pso_base_ent *ne = &g_pbase[g_npbase]; ne->k = b; ne->p = base; ne->job = job;
            bi = g_npbase++;
            pf_note(&b, 1, pso_desc(&b, pg, 1));
            if (job) { g_pso_pend = 1; return nil; }
        }
        pso_base_ent *be = &g_pbase[bi];
        if (!be->p) return nil;   // 异步编失败：已报红，不再重试
        // 包归档（出包按各局收来的「特化管线」预编，第一局用）/ 设备归档（上次运行特化后后台按完整描述编进去的，之后的局用）里有这条的完整版：直接用，不特化
        //   iPhone 上特化与程序不无关（10-22 动森预热成功的组合照样慢 3.0 ms），不能靠系统缓存复用
        { id fd = pso_desc(k, pg, 0); id q = pso_pf_take(k, 0);
          if (!q && (q = gal_pso_pack_lookup(fd))) g_spec_pack_hit++;
          else if (!q && gal_pso_dev_dir() && (q = gal_pso_dev_lookup(fd))) g_spec_dev_hit++;
          if (q) { pf_note(k, 0, fd); return q; } }
        p = gal_specialize_render_pso(pso_desc(k, pg, 0), be->p, &e);
        if (!p) { static int n; if (n++ < 8) GLOG("【红】管线特化失败（程序 %016llx）：%s", (unsigned long long)pg->hash, e.localizedDescription.UTF8String); return nil; }
        gal_pso_note_desc(pso_desc(k, pg, 0));
        pf_note(k, 0, pso_desc(k, pg, 0));
        // 特化结果：后台按完整描述编一条进设备归档
        if (gal_pso_dev_dir()) gal_pso_dev_capture(pso_desc(k, pg, 0));
        return p;
    }
    if (!(p = pso_pf_take(k, 0))) p = gal_new_render_pso(pso_desc(k, pg, 0), &e);
    if (p) pf_note(k, 0, pso_desc(k, pg, 0));
    if (!p) { static int n; if (n++ < 8) GLOG("【红】渲染管线编译失败（程序 %016llx）：%s", (unsigned long long)pg->hash, e.localizedDescription.UTF8String); }
    return p;
}
// 诊断 NXGAL_PSO_LOG=<文件>：每次现建管线记一行——程序哈希、片元输出摘要（颜色格式 / 多重采样 / 混合 / 写掩码 / a2c）、顶点布局摘要（属性格式偏移缓冲 + 步进）、拓扑类别、只光栅化、耗时 ms。
// 定管线预建方案用：同程序的多个管线各差在哪一类（Metal 4 只能留空片元输出那一截）
static void pso_log(const pso_key *k, uint64_t t0) {
    static FILE *f; static int on = -1;
    if (on < 0) { const char *v = getenv("NXGAL_PSO_LOG"); on = v && *v; if (on) { f = fopen(v, "w"); if (f) fprintf(f, "prog\tfrag_out\tvlayout\ttopo\tdiscard\tms\n"); else on = 0; } }
    if (!on) return;
    static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb);
    uint64_t fo = fnv(k->cf, sizeof k->cf) ^ fnv(&k->samples, 4) * 3 ^ fnv(k->blend, sizeof k->blend) * 5 ^ fnv(k->mask, sizeof k->mask) * 7 ^ (uint64_t)(k->a2c | k->a2one << 1) * 11;
    uint64_t vl = fnv(k->attr, sizeof k->attr) ^ fnv(k->vb, sizeof k->vb) * 3;
    fprintf(f, "%016llx\t%016llx\t%016llx\t%u\t%u\t%.2f\n", (unsigned long long)k->prog_hash, (unsigned long long)fo, (unsigned long long)vl, k->topo_class, k->discard, (mach_absolute_time() - t0) * tb.numer / tb.denom / 1e6);
    fflush(f);
}

// ---------- 通用特化预热（10-22 动森首遇特化慢根治：RG16Float 只写 R 这类组合冷缓存特化 2–3 ms）----------
// 前提（前提探针 NXGAL_SPEC_PROBE2 实测，Mac 与 iPhone）：特化代价按单附件「格式 × 混合 × 写掩码」组合记，与程序、附件序号无关，多附件管线照样复用，
//   跨进程保留（iPhone 同包第二局 0.08–0.12 ms；新装包后头一次 1–3.4 ms）。所以启动时在编译器线程上把组合表在任意基础管线（清屏片元）上各特化一次，
//   之后所有程序首遇同组合都只取缓存。表 = 可渲染颜色格式 × 部分写掩码 1–14（不混合）+ 九款录像里出现过的混合 / 部分掩码组合（10-21 缩键测算 70 种）。
//   每次启动都做：缓存在时每条约 0.1 ms，都在编译器线程上，不占渲染线程
static const struct { int16_t f; uint8_t en; uint32_t b[6]; uint8_t mask; } k_spec_seen[] = {
    {F_R10G10B10A2Unorm, 1, {1, 5, 2, 1, 5, 2}, 0xf},
    {F_R10G10B10A2Unorm, 1, {1, 5, 6, 1, 5, 6}, 0xf},
    {F_R10G10B10A2Unorm, 1, {1, 5, 6, 5, 2, 2}, 0xf},
    {F_R11G11B10Float, 0, {0, 0, 0, 0, 0, 0}, 0x7},
    {F_R11G11B10Float, 1, {1, 1, 3, 1, 1, 3}, 0x7},
    {F_R11G11B10Float, 1, {1, 2, 2, 1, 2, 1}, 0x7},
    {F_R11G11B10Float, 1, {1, 2, 2, 1, 2, 2}, 0x0},
    {F_R11G11B10Float, 1, {1, 2, 2, 1, 2, 2}, 0xf},
    {F_R11G11B10Float, 1, {1, 2, 5, 1, 1, 5}, 0xf},
    {F_R11G11B10Float, 1, {1, 2, 5, 1, 2, 1}, 0xf},
    {F_R11G11B10Float, 1, {1, 2, 5, 1, 2, 5}, 0x7},
    {F_R11G11B10Float, 1, {1, 2, 6, 1, 2, 2}, 0xf},
    {F_R11G11B10Float, 1, {1, 2, 49153, 1, 2, 49153}, 0xf},
    {F_R11G11B10Float, 1, {1, 5, 2, 1, 2, 1}, 0xf},
    {F_R11G11B10Float, 1, {1, 5, 2, 1, 5, 1}, 0x7},
    {F_R11G11B10Float, 1, {1, 5, 2, 1, 5, 2}, 0xf},
    {F_R11G11B10Float, 1, {1, 5, 6, 1, 1, 6}, 0xf},
    {F_R11G11B10Float, 1, {1, 5, 6, 1, 2, 1}, 0xf},
    {F_R11G11B10Float, 1, {1, 5, 6, 1, 5, 6}, 0x7},
    {F_R11G11B10Float, 1, {1, 5, 6, 1, 5, 6}, 0xf},
    {F_R11G11B10Float, 1, {1, 5, 6, 5, 2, 2}, 0xf},
    {F_R11G11B10Float, 1, {1, 49153, 2, 1, 2, 1}, 0xf},
    {F_R11G11B10Float, 1, {1, 49155, 49156, 1, 49155, 49156}, 0xf},
    {F_R16Float, 1, {1, 5, 2, 1, 5, 2}, 0xf},
    {F_R16Float, 1, {1, 5, 6, 1, 5, 6}, 0xf},
    {F_R16G16B16A16Float, 0, {0, 0, 0, 0, 0, 0}, 0x1},
    {F_R16G16B16A16Float, 0, {0, 0, 0, 0, 0, 0}, 0x6},
    {F_R16G16B16A16Float, 0, {0, 0, 0, 0, 0, 0}, 0x7},
    {F_R16G16B16A16Float, 1, {1, 2, 2, 1, 2, 2}, 0xf},
    {F_R16G16B16A16Float, 1, {1, 5, 6, 1, 1, 6}, 0xf},
    {F_R16G16B16A16Unorm, 1, {1, 49155, 49156, 1, 49155, 49156}, 0xf},
    {F_R16Unorm, 0, {0, 0, 0, 0, 0, 0}, 0x1},
    {F_R16Unorm, 1, {1, 2, 1, 1, 2, 1}, 0x1},
    {F_R32Float, 0, {0, 0, 0, 0, 0, 0}, 0x1},
    {F_R32G32B32A32Float, 1, {1, 2, 2, 1, 2, 2}, 0xf},
    {F_R32G32B32A32Float, 1, {1, 5, 2, 1, 1, 6}, 0xf},
    {F_R8G8B8A8Srgb, 1, {1, 5, 6, 1, 5, 6}, 0xf},
    {F_R8G8B8A8Unorm, 0, {0, 0, 0, 0, 0, 0}, 0x4},
    {F_R8G8B8A8Unorm, 0, {0, 0, 0, 0, 0, 0}, 0x7},
    {F_R8G8B8A8Unorm, 0, {0, 0, 0, 0, 0, 0}, 0x8},
    {F_R8G8B8A8Unorm, 0, {0, 0, 0, 0, 0, 0}, 0xe},
    {F_R8G8B8A8Unorm, 1, {1, 1, 3, 1, 1, 5}, 0xf},
    {F_R8G8B8A8Unorm, 1, {1, 1, 3, 1, 1, 6}, 0xf},
    {F_R8G8B8A8Unorm, 1, {1, 1, 6, 1, 1, 6}, 0x1},
    {F_R8G8B8A8Unorm, 1, {1, 1, 6, 1, 1, 6}, 0x8},
    {F_R8G8B8A8Unorm, 1, {1, 2, 2, 1, 2, 2}, 0xf},
    {F_R8G8B8A8Unorm, 1, {1, 2, 4, 1, 2, 4}, 0x7},
    {F_R8G8B8A8Unorm, 1, {1, 2, 4, 1, 2, 4}, 0xf},
    {F_R8G8B8A8Unorm, 1, {1, 2, 5, 1, 2, 5}, 0x7},
    {F_R8G8B8A8Unorm, 1, {1, 2, 6, 1, 2, 6}, 0xf},
    {F_R8G8B8A8Unorm, 1, {1, 5, 2, 1, 5, 2}, 0x7},
    {F_R8G8B8A8Unorm, 1, {1, 5, 2, 1, 5, 2}, 0xf},
    {F_R8G8B8A8Unorm, 1, {1, 5, 6, 1, 1, 6}, 0xf},
    {F_R8G8B8A8Unorm, 1, {1, 5, 6, 1, 5, 6}, 0x0},
    {F_R8G8B8A8Unorm, 1, {1, 5, 6, 1, 5, 6}, 0x7},
    {F_R8G8B8A8Unorm, 1, {1, 5, 6, 1, 5, 6}, 0xf},
    {F_R8G8B8A8Unorm, 1, {1, 5, 6, 5, 2, 2}, 0xf},
    {F_R8G8B8A8Unorm, 1, {1, 10, 2, 1, 10, 2}, 0xf},
    {F_R8G8B8A8Unorm, 1, {1, 49153, 5, 1, 49153, 5}, 0xf},
    {F_R8G8B8A8Unorm, 1, {1, 49155, 49156, 1, 49155, 49156}, 0xf},
    {F_R8G8B8A8Unorm, 1, {3, 2, 2, 3, 2, 2}, 0xf},
    {F_R8G8B8A8Unorm, 1, {4, 5, 6, 4, 5, 6}, 0x2},
    {F_R8G8B8A8Unorm, 1, {5, 5, 6, 5, 5, 6}, 0xf},
    {F_R8G8Unorm, 0, {0, 0, 0, 0, 0, 0}, 0x3},
    {F_R8G8Unorm, 1, {4, 5, 6, 4, 5, 6}, 0x2},
    {F_R8Unorm, 0, {0, 0, 0, 0, 0, 0}, 0x1},
    {F_R8Unorm, 0, {0, 0, 0, 0, 0, 0}, 0x3},
    {F_R8Unorm, 0, {0, 0, 0, 0, 0, 0}, 0x7},
    {F_R8Unorm, 1, {1, 2, 2, 1, 2, 2}, 0xf},
    {F_R8Unorm, 1, {1, 2, 6, 1, 2, 2}, 0xf},
};
static _Atomic uint64_t g_sc_st[4];   // 0 起 1 完成 2 失败 3 本进程记下的「特化组合」行
static _Atomic int g_sc_pend;   // 还在后台提交的批数（单测等它归 0）
void gal_spec_combo_stats(uint64_t out[4]) { for (int i = 0; i < 4; i++) out[i] = g_sc_st[i]; if (g_sc_pend) out[0] = UINT64_MAX; }
// 预热状态（慢特化诊断用）：键 = Metal 层颜色附件描述（格式 / 写掩码 / 混合开关 / 6 个混合枚举），与 gal_core.m 慢特化行同一口径
typedef struct { uint64_t key; int st; } sc_st;   // st：1 在编 2 成功 3 失败
static sc_st *g_scs; static int g_nscs, g_capscs; static pthread_mutex_t g_scs_mu = PTHREAD_MUTEX_INITIALIZER;
static uint64_t g_sc_t0; static _Atomic int g_sc_logged;
static uint64_t ca_key(id c) {
    uint64_t v[9] = {(uint64_t)[c pixelFormat], [[c valueForKey:@"writeMask"] unsignedLongValue], (uint64_t)[[c valueForKey:@"blendingState"] longValue], 0, 0, 0, 0, 0, 0};
    if (v[2] == 1) { NSString *const k[6] = {@"rgbBlendOperation", @"sourceRGBBlendFactor", @"destinationRGBBlendFactor", @"alphaBlendOperation", @"sourceAlphaBlendFactor", @"destinationAlphaBlendFactor"};
        for (int i = 0; i < 6; i++) v[3 + i] = (uint64_t)[[c valueForKey:k[i]] longValue]; }
    return fnv(v, sizeof v);
}
int gal_spec_combo_status(id ca) {
    uint64_t k = ca_key(ca); int st = 0;
    pthread_mutex_lock(&g_scs_mu); for (int i = 0; i < g_nscs && !st; i++) if (g_scs[i].key == k) st = g_scs[i].st; pthread_mutex_unlock(&g_scs_mu);
    return st;
}
static double spec_ms(uint64_t t0);
static void sc_maybe_log(void);
static void sc_done(int idx, int ok) {
    pthread_mutex_lock(&g_scs_mu); g_scs[idx].st = ok ? 2 : 3; pthread_mutex_unlock(&g_scs_mu);
    g_sc_st[ok ? 1 : 2]++; sc_maybe_log();
}
// 后台提交都结束、且全部完成时打一次汇总（最后一条完成可能早于提交循环结束，两处都判）
static void sc_maybe_log(void) {
    if (!g_sc_pend && g_sc_st[1] + g_sc_st[2] >= g_sc_st[0] && !atomic_exchange(&g_sc_logged, 1))
        GLOG("通用特化预热完成：%llu 条，成功 %llu、失败 %llu，自起预热 %.0f ms", (unsigned long long)g_sc_st[0], (unsigned long long)g_sc_st[1], (unsigned long long)g_sc_st[2], spec_ms(g_sc_t0));
}
static void spec_combo_pf(id<MTLRenderPipelineState> const base3[3], MTLPixelFormat pf, int ct, const uint32_t *blend7, uint8_t mask) {
    if (pf == MTLPixelFormatInvalid || (unsigned)ct > 2) return;
    // RGB9E5Float 只许写掩码全开或全关（Metal 不支持部分通道）：这类组合游戏真用到时 pso_desc_colors 按全写并报红，预热它没有意义；
    //   10-24 预热网格「格式 × 写掩码 1–15」把它喂进报红分支，九款正式局每局恰好 1 行红、能玩格全红
    if (pf == MTLPixelFormatRGB9E5Float && mask && mask != 0xf) return;
    id<MTLRenderPipelineState> base = base3[ct]; id d = base ? gal_clr_spec_desc(ct) : nil; if (!d) return;
    pso_key k; memset(&k, 0, sizeof k); k.cf[0] = (uint32_t)pf; k.mask[0] = mask; if (blend7) memcpy(k.blend[0], blend7, sizeof k.blend[0]);
    pso_desc_colors(d, &k); g_sc_st[0]++;
    pthread_mutex_lock(&g_scs_mu);
    if (g_nscs == g_capscs) { g_capscs = g_capscs ? g_capscs * 2 : 1024; g_scs = realloc(g_scs, g_capscs * sizeof *g_scs); }
    int idx = g_nscs++; g_scs[idx].key = ca_key([[d colorAttachments] objectAtIndexedSubscript:0]); g_scs[idx].st = 1;
    pthread_mutex_unlock(&g_scs_mu);
    gal_specialize_render_pso_async(d, base, ^(id<MTLRenderPipelineState> p) { sc_done(idx, p != nil); });
}
static void spec_combo(id<MTLRenderPipelineState> const base3[3], int32_t f, const uint32_t *blend7, uint8_t mask) { spec_combo_pf(base3, gal_fmt_mtl(f), gal_fmt_ctype(f), blend7, mask); }
// Metal 格式 → 输出类型（运行时组合行记的是 Metal 格式）：按 GAL 格式表反查，缩放整数格式（按浮点读的顶点格式）不算
static int mtl_ctype(MTLPixelFormat pf) {
    for (int32_t f = 0; f < F_COUNT; f++) {
        if ((f >= F_R8Uscaled && f <= F_R32G32B32A32Sscaled) || f == F_R10G10B10A2Uscaled || f == F_R10G10B10A2Sscaled) continue;
        if (gal_fmt_mtl(f) == pf) return gal_fmt_ctype(f);
    }
    return 0;
}
// 运行时特化记「特化组合」行（出包 speccombo.py 收成全款通用表）：只记开混合或部分写掩码的单附件组合（不混合的全写 / 部分写由启动网格「格式 × 写掩码 1–15」全覆盖），本进程去重
typedef struct { uint32_t pf, b[7]; uint8_t mask; } sc_ent;
static sc_ent *g_scl; static int g_nscl, g_capscl;
static void spec_combo_note(const pso_key *k) {
    for (int i = 0; i < 8; i++) {
        if (!k->cf[i] || (!k->blend[i][0] && (k->mask[i] == 0xf || !k->mask[i]))) continue;
        sc_ent e; memset(&e, 0, sizeof e); e.pf = k->cf[i]; e.mask = k->mask[i]; if (k->blend[i][0]) memcpy(e.b, k->blend[i], sizeof e.b);
        int dup = 0; for (int j = 0; j < g_nscl && !dup; j++) dup = !memcmp(&g_scl[j], &e, sizeof e);
        if (dup) continue;
        if (g_nscl == g_capscl) { g_capscl = g_capscl ? g_capscl * 2 : 64; g_scl = realloc(g_scl, g_capscl * sizeof *g_scl); }
        g_scl[g_nscl++] = e; g_sc_st[3]++;
        GLOG("特化组合 v1 %u %d %u %u %u %u %u %u %u %u", e.pf, mtl_ctype((MTLPixelFormat)e.pf), e.b[0], e.b[1], e.b[2], e.b[3], e.b[4], e.b[5], e.b[6], e.mask);
    }
}
int gal_spec_combo_load(const char *path) {
    if (!gal_pso_can_specialize()) return 0;
    FILE *f = fopen(path, "r"); if (!f) return 0;
    char line[256]; int n = 0, cap = 0; struct { uint32_t pf, b[7]; int ct; uint8_t mask; } *t = NULL;
    while (fgets(line, sizeof line, f)) {
        unsigned pf, b[7], m; int ct;
        if (line[0] == '#' || sscanf(line, "v1 %u %d %u %u %u %u %u %u %u %u", &pf, &ct, &b[0], &b[1], &b[2], &b[3], &b[4], &b[5], &b[6], &m) != 10) continue;
        if (n == cap) { cap = cap ? cap * 2 : 64; t = realloc(t, cap * sizeof *t); }
        t[n].pf = pf; t[n].ct = ct; memcpy(t[n].b, b, sizeof t[n].b); t[n].mask = (uint8_t)m; n++;
    }
    fclose(f);
    GLOG("特化组合表：%d 条（%s），后台补预热", n, path);
    if (!n) { free(t); return 0; }
    // 清屏基础管线是渲染器内部管线：载入组合表在登记着色器包时（nxgal_warm_internal 之前），按内部预建记，不算游戏首遇现建
    //   （10-22 九款冷启动首局格全红：第 1 帧 3 条 clr_vs / clr_fs_*0「管线现建」计进 pso_n）
    gal_pso_warming_push();
    id<MTLRenderPipelineState> b0 = gal_clr_spec_base(0), b1 = gal_clr_spec_base(1), b2 = gal_clr_spec_base(2);
    gal_pso_warming_pop();
    g_sc_pend++;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        id<MTLRenderPipelineState> base3[3] = {b0, b1, b2};
        for (int i = 0; i < n; i++) spec_combo_pf(base3, (MTLPixelFormat)t[i].pf, t[i].ct, t[i].b[0] ? t[i].b : NULL, t[i].mask);
        free(t); g_sc_pend--; sc_maybe_log();
    });
    return n;
}
static double spec_ms(uint64_t t0) { static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb); return (double)(mach_absolute_time() - t0) * tb.numer / tb.denom / 1e6; }
void gal_warm_spec_combos(void) {
    static int done; if (done || !gal_pso_can_specialize()) return; done = 1;
    // 基础管线在调用线程（渲染线程）上取（清屏基础管线表只在这里改）；提交循环整段放后台队列：742 条逐条提交在调用线程上约 0.8 秒（Mac），不拖启动
    id<MTLRenderPipelineState> b0 = gal_clr_spec_base(0), b1 = gal_clr_spec_base(1), b2 = gal_clr_spec_base(2);
    g_sc_pend++; g_sc_t0 = mach_absolute_time();
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        id<MTLRenderPipelineState> base3[3] = {b0, b1, b2};
        uint64_t t0 = mach_absolute_time(); MTLPixelFormat seenpf[F_COUNT]; int nseen = 0;
        for (int32_t f = 0; f < F_COUNT; f++) {
            // 可渲染颜色格式：非深度模板、非压缩（BC / ETC2 / ASTC）、非缩放整数（按浮点读的顶点格式）；同一个 Metal 格式只做一遍
            if (gal_fmt_is_ds(f) || (f >= F_Bc1RgbaUnorm && f <= F_Etc2RgbPtaSrgb) || (f >= F_Astc4x4Unorm && f <= F_Astc12x12Srgb)) continue;
            if ((f >= F_R8Uscaled && f <= F_R32G32B32A32Sscaled) || f == F_R10G10B10A2Uscaled || f == F_R10G10B10A2Sscaled) continue;
            MTLPixelFormat pf = gal_fmt_mtl(f); int dup = pf == MTLPixelFormatInvalid; for (int i = 0; i < nseen && !dup; i++) dup = seenpf[i] == pf;
            if (dup) continue; seenpf[nseen++] = pf;
            // 写掩码 1–15：含全写（15）。10-23 塞尔达拷贝写 RG32Float 全写 22.8 ms、怪猎清屏 RGB10A2 全写 2.7 ms：全写不混合同样要真编译（原先假定不编、没进网格）
            for (uint8_t m = 1; m <= 15; m++) spec_combo(base3, f, NULL, m);
        }
        for (size_t i = 0; i < sizeof k_spec_seen / sizeof k_spec_seen[0]; i++) {
            uint32_t b7[7] = {k_spec_seen[i].en, k_spec_seen[i].b[0], k_spec_seen[i].b[1], k_spec_seen[i].b[2], k_spec_seen[i].b[3], k_spec_seen[i].b[4], k_spec_seen[i].b[5]};
            spec_combo(base3, k_spec_seen[i].f, k_spec_seen[i].en ? b7 : NULL, k_spec_seen[i].mask);
        }
        GLOG("通用特化预热：起 %llu 条（%d 种颜色格式 × 写掩码 15 种（含全写） + 录像组合 %zu 种），后台提交用 %.1f ms，编译器线程上做", (unsigned long long)g_sc_st[0], nseen,
             sizeof k_spec_seen / sizeof k_spec_seen[0], spec_ms(t0));
        g_sc_pend--; sc_maybe_log();
    });
}
id<MTLRenderPipelineState> gal_pso_get(const gal_prog *pg, uint8_t *color_round_mask, uint64_t *lop_addr) {
    GP_SCOPE(GP_PSO);
    pso_key k; pso_key_build(&k, pg);
    uint64_t h = gal_draw_fixed() ? key_hash(&k, pso_key_size()) : fnv(&k, pso_key_size());   // NXGAL_DRAW_FIXED=0：旧逐字节 FNV（进程内不变，查表 / 插入 / 重建一致）
    if (g_pso_hcap) for (uint32_t i = (uint32_t)h & (g_pso_hcap - 1);; i = (i + 1) & (g_pso_hcap - 1)) {
        uint32_t s = g_pso_hash[i]; if (!s) break;
        if (memcmp(&g_pso[s - 1].k, &k, pso_key_size())) continue;
        pso_ent *pe = &g_pso[s - 1];
        if (color_round_mask) *color_round_mask = pe->color_round_mask;
        if (lop_addr) *lop_addr = pe->lop_addr;
        return pe->p;
    }
    uint64_t t0 = mach_absolute_time(), s0 = gal_pso_spec_count();
    g_pso_pend = 0; id<MTLRenderPipelineState> p = pso_build(&k, pg);
    if (g_pso_pend) return nil;   // 基础管线异步现建中：不进管线表，下次绘制再来取
    pso_log(&k, t0);
    if (p && gal_pso_spec_count() != s0) spec_combo_note(&k);   // 本次是运行时特化：记下真编译类组合（出包收进通用表）
    if (g_npso == g_cappso) { g_cappso = g_cappso ? g_cappso * 2 : 256; g_pso = realloc(g_pso, g_cappso * sizeof *g_pso); memset((void *)(g_pso + g_npso), 0, (g_cappso - g_npso) * sizeof *g_pso); }
    g_pso[g_npso].k = k; g_pso[g_npso].p = p;
    g_pso[g_npso].color_round_mask = pso_color_round_mask(&k, pg);
    if (color_round_mask) *color_round_mask = g_pso[g_npso].color_round_mask;
    g_pso[g_npso].lop_addr = lop_addr_of(&k);
    if (k.lop && !g_pso[g_npso].lop_addr) g_pso[g_npso].p = p = nil;   // 参数表取不到（已报红）：_lo 管线没参数可读，不画
    if (lop_addr) *lop_addr = g_pso[g_npso].lop_addr;
    g_npso++;
    if (g_npso * 2 > g_pso_hcap) {   // 重建哈希表
        g_pso_hcap = g_pso_hcap ? g_pso_hcap * 2 : 512; free(g_pso_hash); g_pso_hash = calloc(g_pso_hcap, sizeof *g_pso_hash);
        for (int j = 0; j < g_npso; j++) { uint64_t hj = gal_draw_fixed() ? key_hash(&g_pso[j].k, pso_key_size()) : fnv(&g_pso[j].k, pso_key_size()); uint32_t i = (uint32_t)hj & (g_pso_hcap - 1); while (g_pso_hash[i]) i = (i + 1) & (g_pso_hcap - 1); g_pso_hash[i] = j + 1; }
    } else { uint32_t i = (uint32_t)h & (g_pso_hcap - 1); while (g_pso_hash[i]) i = (i + 1) & (g_pso_hcap - 1); g_pso_hash[i] = g_npso; }
    return p;
}
int gal_pso_count(void) { return g_npso; }
// 单测钩子（tests/t_m3pso.m）：按当前 GAL 状态 + 给定程序出管线描述（与 pso_build 走同一条 pso_desc），只给单测核类型 / 字段，不建管线
NXGAL_API id nxgal_test_pso_desc(const gal_prog *pg, int32_t unspec) { pso_key k; if (!pso_key_build(&k, pg)) return nil; return pso_desc(&k, pg, unspec); }

// ---------- 深度模板状态缓存 ----------
// 键 = 深度测试 + 模板测试（参考值是动态状态，清零后进键）+ 目标有无深度 / 模板
typedef struct { nxgal_depth_test d; nxgal_stencil s; int has_depth, has_stencil; } dss_key;
typedef struct { dss_key k; id<MTLDepthStencilState> s; } dss_ent;
static dss_ent *g_dss; static int g_ndss;
id<MTLDepthStencilState> gal_dss_get(int has_depth, int has_stencil) {
    dss_key k; memset(&k, 0, sizeof k);
    k.has_depth = has_depth; k.has_stencil = has_stencil;
    if (has_depth) k.d = g_gs.depth;
    if (has_stencil && g_gs.stencil.enable) { k.s = g_gs.stencil; k.s.front_ref = k.s.back_ref = 0; }
    for (int i = 0; i < g_ndss; i++) if (!memcmp(&g_dss[i].k, &k, sizeof k)) return g_dss[i].s;
    const nxgal_stencil *s = &k.s;
    MTLDepthStencilDescriptor *d = [MTLDepthStencilDescriptor new];
    if (has_depth && k.d.test) { d.depthCompareFunction = gal_cmp(k.d.func); d.depthWriteEnabled = k.d.write != 0; }
    else { d.depthCompareFunction = MTLCompareFunctionAlways; d.depthWriteEnabled = NO; }   // Vulkan：深度测试关 = 不测也不写
    if (s->enable) {
        MTLStencilDescriptor *f = [MTLStencilDescriptor new], *b = [MTLStencilDescriptor new];
        f.stencilCompareFunction = gal_cmp(s->front_func); f.stencilFailureOperation = sop(s->front_sfail); f.depthFailureOperation = sop(s->front_dpfail); f.depthStencilPassOperation = sop(s->front_dppass);
        f.readMask = s->front_func_mask & 0xff; f.writeMask = s->front_mask & 0xff;
        b.stencilCompareFunction = gal_cmp(s->back_func); b.stencilFailureOperation = sop(s->back_sfail); b.depthFailureOperation = sop(s->back_dpfail); b.depthStencilPassOperation = sop(s->back_dppass);
        b.readMask = s->back_func_mask & 0xff; b.writeMask = s->back_mask & 0xff;
        d.frontFaceStencil = f; d.backFaceStencil = b;
    }
    id<MTLDepthStencilState> st = [g_gdev newDepthStencilStateWithDescriptor:d];
    dss_ent *nd = gal_grow(g_dss, (size_t)g_ndss + 1, sizeof *g_dss, "深度模板状态缓存"); if (!nd) return st;   // 扩不了（P1-44）：这次照用、不进缓存
    g_dss = nd; memset((void *)&g_dss[g_ndss], 0, sizeof *g_dss);
    g_dss[g_ndss].k = k; g_dss[g_ndss].s = st; g_ndss++;
    return st;
}

// ---------- 绘制前应用动态状态（视口 / 剪裁 / 剔除 / 绕序 / 填充 / 深度偏移 / 深度夹紧 / 模板参考 / 混合常量）----------
void gal_state_apply_dynamic(id<MTL4RenderCommandEncoder> e, int rt_w, int rt_h, int has_depth, int has_stencil) {
    GP_SCOPE(GP_DYN);
    MTLViewport vp[16]; int n = g_gs.nvp ? g_gs.nvp : 1;
    for (int i = 0; i < n; i++) {
        if (!g_gs.nvp) { vp[i] = (MTLViewport){0, 0, rt_w, rt_h, 0, 1}; continue; }
        const nxgal_viewport *v = &g_gs.vp[i];
        float w = v->w == 0 ? 1 : v->w, h = v->h == 0 ? 1 : v->h;
        float zn = v->znear < 0 ? 0 : v->znear > 1 ? 1 : v->znear, zf = v->zfar < 0 ? 0 : v->zfar > 1 ? 1 : v->zfar;
        vp[i] = (MTLViewport){v->x, v->y + h, w, -h, zn, zf};
    }
    [e setViewports:vp count:n];
    MTLScissorRect sc[16]; int ns = g_nscissors < n ? g_nscissors : n; if (ns < 1) ns = 1;
    for (int i = 0; i < n; i++) {
        const nxgal_rect *r = &g_scissors[i < g_nscissors ? i : 0];
        long x0 = r->x < 0 ? 0 : r->x, y0 = r->y < 0 ? 0 : r->y, x1 = (long)r->x + r->w, y1 = (long)r->y + r->h;
        if (x1 > rt_w) x1 = rt_w; if (y1 > rt_h) y1 = rt_h;
        if (x0 > rt_w) x0 = rt_w; if (y0 > rt_h) y0 = rt_h;
        sc[i] = (MTLScissorRect){(NSUInteger)x0, (NSUInteger)y0, (NSUInteger)(x1 > x0 ? x1 - x0 : 0), (NSUInteger)(y1 > y0 ? y1 - y0 : 0)};
    }
    if (g_gs.discard) memset(sc, 0, sizeof sc);   // 光栅化丢弃：剪裁置空，不出片元（见 pso_desc）
    [e setScissorRects:sc count:n];
    MTLCullMode cm = MTLCullModeNone;
    if (g_gs.cull_en) cm = g_gs.cull_face == 0x404 ? MTLCullModeFront : g_gs.cull_face == 0x405 ? MTLCullModeBack : MTLCullModeNone;
    { static int nocull = -1; if (nocull < 0) nocull = getenv("NXGAL_DEBUG_NOCULL") != NULL; if (nocull) cm = MTLCullModeNone; }   // 诊断开关：强制不剔除
    [e setCullMode:cm];
    [e setFrontFacingWinding:g_gs.front_face == 0x900 ? MTLWindingCounterClockwise : MTLWindingClockwise];   // 同 Vulkan 后端 EnumConversion：GAL 正面按 OpenGL Y 朝上定义，帧缓冲坐标下取反
    [e setTriangleFillMode:g_gs.poly == 0x1b01 ? MTLTriangleFillModeLines : MTLTriangleFillModeFill];
    if (g_gs.poly == 0x1b00) GRED_ONCE("多边形点模式未实现，按填充画");
    int mode_bit = g_gs.poly == 0x1b00 ? 1 : g_gs.poly == 0x1b01 ? 2 : 4;
    if (g_gs.bias_en & mode_bit) [e setDepthBias:g_gs.bias_units slopeScale:g_gs.bias_factor clamp:g_gs.bias_clamp];
    else [e setDepthBias:0 slopeScale:0 clamp:0];
    [e setDepthClipMode:g_gs.depth_clamp ? MTLDepthClipModeClamp : MTLDepthClipModeClip];
    if (has_stencil && g_gs.stencil.enable) [e setStencilFrontReferenceValue:g_gs.stencil.front_ref & 0xff backReferenceValue:g_gs.stencil.back_ref & 0xff];
    const float *c = g_gs.blend[0].constant;
    [e setBlendColorRed:c[0] green:c[1] blue:c[2] alpha:c[3]];
    [e setDepthStencilState:gal_dss_get(has_depth, has_stencil)];
}
int gal_state_cull_all(void) { return g_gs.cull_en && g_gs.cull_face == 0x408; }
GAL_MTL4_ZONE_END
