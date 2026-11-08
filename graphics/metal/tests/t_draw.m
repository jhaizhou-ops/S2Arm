// 第 5 / 6 块单测：手写 MSL 程序（参数缓冲第 2 档布局）+ 手搭 gal_prog，走 nxgal_* 全路径画到离屏目标，读回比手算期望。
// 缓冲 / 采样器 / 程序均用真实现（第 2 / 3 / 4 块已合入）。
// 期望值来源：Vulkan 规范（正面判定、视口映射）+ 手算混合 / 量化，不跑被测实现。
#import <Metal/Metal.h>
#include "fixture.h"   // 固定 MSL 走离线 metallib 夹具（不是被测对象，不经运行时编译服务）
#include "../gal_abi.h"
#include "../gal_internal.h"
#include "../gal_formats.h"
#include <stdio.h>
#include <string.h>
#include <mach/mach.h>

// 缓冲 / 采样器 / 程序都用已合入的真实现：stub_buf 把一块 MTLBuffer 内容转成 GAL 缓冲，手搭程序经内置程序接口登记
GAL_MTL4_ZONE_BEGIN   // Metal 4 可用性区（gal_internal.h）
static uint32_t stub_buf(id<MTLBuffer> b) { uint32_t bid = nxgal_buf_create((int32_t)b.length, 0); nxgal_buf_set_data(bid, 0, b.contents, (int32_t)b.length); return bid; }
static uint32_t stub_prog(gal_prog *p) { return gal_prog_register_builtin(p); }
static uint32_t stub_sampler(id<MTLSamplerState> s) {   // 最近邻、夹边
    (void)s; nxgal_sampler_info i = {1, 1, 1, 2, 2, 2, 0, 8, {0, 0, 0, 0}, 0, 1000, 0, 1}; return nxgal_sampler_create(&i);
}

uint64_t gal_buf_read_gpu(uint32_t bid, int32_t offset, int32_t len);
extern uint64_t gal_rebind_n;
static int g_fail, g_checks;
#define CHECK(cond, ...) do { g_checks++; if (!(cond)) { g_fail++; printf("  ✗ " __VA_ARGS__); printf("\n"); } } while (0)

static NSString *const k_msl = @
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"struct VIn { float4 pos [[attribute(0)]]; };\n"
"struct VOut { float4 pos [[position]]; };\n"
"struct Set0 { constant float4 *ubo [[id(0)]]; };\n"
"struct Set2 { texture2d<float> t [[id(0)]]; sampler s [[id(1)]]; };\n"
"vertex VOut vs(VIn in [[stage_in]]) { VOut o; o.pos = float4(in.pos.xyz, 1.0); return o; }\n"
"fragment float4 fs(VOut in [[stage_in]], constant Set0 &s0 [[buffer(0)]], constant Set2 &s2 [[buffer(2)]]) {\n"
"  return s0.ubo[0] * s2.t.sample(s2.s, float2(0.5)); }\n"
"struct Set1 { device uint *out [[id(0)]]; };\n"
"struct VOP { float4 pos [[position]]; float ps [[point_size]]; };\n"
"vertex VOP vs_ps(VIn in [[stage_in]]) { VOP o; o.pos = float4(in.pos.xyz, 1.0); o.ps = 1.0; return o; }\n"
"kernel void cs(constant Set1 &s1 [[buffer(1)]], uint g [[thread_position_in_grid]]) { s1.out[g] = g * 3u + 7u; }\n"
"struct Set1b { device uchar *out [[id(0)]]; };\n"
"kernel void cs_flip(constant Set1b &s1 [[buffer(1)]], uint g [[thread_position_in_grid]]) {\n"
"  if (g >= 4u) return; device uchar *p = s1.out + g * 13u;\n"
"  uchar4 o = as_type<uchar4>(-as_type<float>(uchar4(p[0], p[1], p[2], p[3]))); p[0] = o.x; p[1] = o.y; p[2] = o.z; p[3] = o.w; }\n"
"struct SetI { texture_buffer<uint, access::write> t [[id(0)]]; };\n"
"kernel void cs_img(constant SetI &s1 [[buffer(1)]], uint g [[thread_position_in_grid]]) {\n"
"  if (g >= 52u) return; uint k = g / 13u, i = g % 13u;\n"
"  float3 v = float3((k == 1u || k == 2u) ? 1.0f : 0.0f, k >= 2u ? 1.0f : -1.0f, 0.0f);\n"
"  uint b = i == 12u ? 0xEEu : uint(as_type<uchar4>(v[i / 4u])[i % 4u]); s1.t.write(b, g); }\n"
"struct SetTB { texture2d<float> t [[id(0)]]; texture_buffer<float> b [[id(1)]]; device float *out [[id(2)]]; };\n"
"kernel void cs_tb(constant SetTB &s1 [[buffer(1)]], uint g [[thread_position_in_grid]]) {\n"
"  if (g != 0u) return; s1.out[0] = s1.t.read(uint2(0)).x; s1.out[1] = float(s1.b.get_width()); s1.out[2] = s1.b.read(3u).x; }\n"
"struct VOL { float4 pos [[position]]; uint layer [[render_target_array_index]]; };\n"
"vertex VOL vs_l1(VIn in [[stage_in]]) { VOL o; o.pos = float4(in.pos.xyz, 1.0); o.layer = 1; return o; }\n"
"fragment void fs_tl(VOut in [[stage_in]], constant Set1 &s1 [[buffer(1)]]) { atomic_fetch_add_explicit((device atomic_uint *)s1.out, 1u, memory_order_relaxed); }\n";

static MTL4LibraryFunctionDescriptor *fn(id<MTLLibrary> l, NSString *n) { MTL4LibraryFunctionDescriptor *f = [MTL4LibraryFunctionDescriptor new]; f.library = l; f.name = n; return f; }
static gal_arg g_args[3] = {
    {GAL_ARG_UBO, 0, 0, 0, 1, 1u << 5},
    {GAL_ARG_TEX, 2, 0, 0, 1, 1u << 5},
    {GAL_ARG_SMP, 2, 0, 8, 1, 1u << 5},
};
static gal_arg g_cargs[1] = {{GAL_ARG_SSBO, 1, 0, 0, 1, 1u << 0}};

enum { RGBA8 = 36, D32F = 51, R32F = 9 };
static nxgal_tex_info ti(int w, int h, int fmt, int bpp) { nxgal_tex_info i = {w, h, 1, 1, 1, 1, 1, bpp, fmt, 0, 1, {2, 3, 4, 5}}; return i; }

static id<MTLBuffer> g_vbuf, g_ubo, g_ibuf, g_sbuf;
static uint32_t g_rt, g_ds, g_white, g_smp, g_prog, g_cprog;

static void set_color(float r, float g, float b, float a) {   // 常量缓冲内容：按命令顺序改要走 SetBufferData；桩阶段直接每次换新缓冲
    id<MTLBuffer> u = [MTLCreateSystemDefaultDevice() newBufferWithLength:16 options:MTLResourceStorageModeShared];
    float c[4] = {r, g, b, a}; memcpy(u.contents, c, 16); gal_res_add(u);
    nxgal_buf_assign a0 = {0, {stub_buf(u), 0, 16, 0}}; nxgal_set_uniform_buffers(&a0, 1);
}
static void set_verts(const float *xyz, int n) {   // 顶点：float3 跨度 12
    id<MTLBuffer> v = [MTLCreateSystemDefaultDevice() newBufferWithBytes:xyz length:n * 12 options:MTLResourceStorageModeShared]; gal_res_add(v);
    nxgal_vbuf vb = {{stub_buf(v), 0, n * 12, 0}, 12, 0}; nxgal_set_vertex_buffers(&vb, 1);
    nxgal_vattr at = {0, 0, 0, 33 /* R32G32B32Float */}; nxgal_set_vertex_attribs(&at, 1);
}
static void base_state(void) {
    nxgal_blend b = {0, {0, 0, 0, 0}, 1, 2, 1, 1, 2, 1}; for (int i = 0; i < 8; i++) nxgal_set_blend(i, &b);
    nxgal_depth_test d = {0, 0, 8}; nxgal_set_depth_test(&d);
    nxgal_stencil s; memset(&s, 0, sizeof s); nxgal_set_stencil_test(&s);
    nxgal_set_face_culling(0, 0x405); nxgal_set_front_face(0x901);
    nxgal_viewport vp = {0, 0, 32, 32, {0, 2, 4, 6}, 0, 1}; nxgal_set_viewports(&vp, 1);
    nxgal_rect sc = {0, 0, 32, 32}; nxgal_set_scissors(&sc, 1);
    uint32_t m[8] = {0xf, 0xf, 0xf, 0xf, 0xf, 0xf, 0xf, 0xf}; nxgal_set_color_masks(m, 8);
    nxgal_set_texture_sampler(5, 0, g_white, g_smp);
    nxgal_set_program(g_prog);
}
static void clear_rt(float r, float g, float b, float a) { float c[4] = {r, g, b, a}; nxgal_rect full = {0, 0, 0xffff, 0xffff}; nxgal_set_scissors(&full, 1); nxgal_clear_color(0, 0, 1, 0xf, c); }
static int read_px(uint8_t px[32 * 32 * 4]) { return nxgal_tex_get_data(g_rt, 0, 0, px, 32 * 32 * 4) == 32 * 32 * 4; }
static int count_px(const uint8_t *px, const uint8_t e[4]) { int n = 0; for (int i = 0; i < 32 * 32; i++) n += !memcmp(px + i * 4, e, 4); return n; }

static const float k_quad[12] = {-1, -1, 0, 1, -1, 0, 1, 1, 0, -1, 1, 0};   // 四边形：规范化坐标四角

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    // 计数格建缓冲失败注入（下方）要计数开；计数缺省关（10-21 起两端同出货口径），本单测显式开。期望全是手算的简单着色器，不含丢弃后导数
    setenv("NXGAL_BOUNDS_COUNT", "1", 1);
    if (nxgal_init(0)) return 2;
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    NSError *err = nil;
    id<MTLLibrary> lib = fx_lib(dev, @"t_draw", k_msl, &err);
    if (!lib) { printf("MSL 编译失败：%s\n", err.localizedDescription.UTF8String); return 2; }
    static gal_prog P, C;
    P.live = 1; P.fn[1] = fn(lib, @"vs"); P.fn[5] = fn(lib, @"fs"); P.set_size[0] = 8; P.set_stages[0] = 1u << 5; P.set_size[2] = 16; P.set_stages[2] = 1u << 5;
    P.args = g_args; P.nargs = 3; P.stage_set_size[5][0] = 8; P.stage_set_size[5][2] = 16; P.vs_inputs = 1; P.fs_outputs = 1; P.hash = 0x1111;
    for (int i = 0; i < 6; i++) P.size_buf_index[i] = -1;
    C.live = 1; C.is_compute = 1; C.fn[0] = fn(lib, @"cs"); C.set_size[1] = 8; C.set_stages[1] = 1u << 0; C.args = g_cargs; C.nargs = 1; C.stage_set_size[0][1] = 8; C.threadgroup = MTLSizeMake(32, 1, 1); C.hash = 0x2222;
    for (int i = 0; i < 6; i++) C.size_buf_index[i] = -1;
    static gal_prog PL; PL = P; PL.fn[1] = fn(lib, @"vs_l1"); PL.hash = 0x3333; PL.vs_writes_layer = 1;   // 顶点写层号 = 1（手搭程序同真记录位 8：管线须指定拓扑）
    g_prog = stub_prog(&P); g_cprog = stub_prog(&C); uint32_t g_lprog = stub_prog(&PL);
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new]; sd.supportArgumentBuffers = YES; g_smp = stub_sampler([dev newSamplerStateWithDescriptor:sd]);
    nxgal_tex_info wi = ti(1, 1, RGBA8, 4); g_white = nxgal_tex_create(&wi); uint8_t w4[4] = {255, 255, 255, 255}; nxgal_tex_set_data(g_white, 0, 0, NULL, w4, 4);
    nxgal_tex_info ri = ti(32, 32, RGBA8, 4); g_rt = nxgal_tex_create(&ri);
    nxgal_tex_info di = ti(32, 32, D32F, 4); g_ds = nxgal_tex_create(&di);
    uint8_t px[32 * 32 * 4];

    // 计数格缓冲建不出（注入）：要在任何绘制之前测——计数开着时第一次绘制带加固着色器就会建好这块缓冲，之后注入测不到。
    // 越界与循环到上限共用一个 16 字节格（gal_spvx.m 常态计数，10-21 合批）；计数关着时格一律指向零缓冲（非 0），不测建缓冲
    if (gal_spvx_counting()) {
        printf("· 越界 / 循环计数格缓冲建不出（注入）：取格返回 0（调用方据此跳过绘制）；撤注入后返回非 0\n");
        gal_newbuf_test_fail = 1;
        CHECK(gal_oob_cell(0x1234) == 0, "注入期间计数格地址期望 0");
        gal_newbuf_test_fail = 0;
        CHECK(gal_oob_cell(0x1234) != 0, "撤注入后计数格地址期望非 0");
    }
    // 建缓冲失败注入（gal_newbuf_test_fail）：首次绘制时 draw_init 建零缓冲失败 → 本次绘制跳过、不崩、目标保持 0；撤注入后下一项照常画（draw_init 重试）。
    // 旧代码反证：memset(nil.contents) 写空指针 SIGSEGV
    printf("· 建缓冲失败（注入）：首次绘制建零缓冲失败 → 跳过不崩、目标保持 0\n");
    nxgal_set_render_targets(&g_rt, 1, 0); base_state(); clear_rt(0, 0, 0, 0);
    set_color(0.2f, 0.4f, 0.6f, 1.0f); set_verts(k_quad, 4); nxgal_set_topology(7);
    gal_newbuf_test_fail = 1; nxgal_draw(4, 1, 0, 0); gal_newbuf_test_fail = 0;
    read_px(px); { uint8_t z[4] = {0, 0, 0, 0}; int n = count_px(px, z); CHECK(n == 1024, "零缓冲建不出：期望 1024 像素保持 0，实得 %d", n); }

    // 绑定阶段中途切遍（10-25 动森 3.0.3 宽屏闭环：4 局都崩在 gal_cnt_on_draw 的 setVisibilityResultMode）：常量缓冲 U 的绑定 [0, 8K) 同时读到
    //   待拷回段（[0, 16) 刚由 CPU 写成红色、走镜像）与 GPU 写在途段（[4K, 8K) 由在录流里的缓冲拷贝写）→ gal_buf_read_gpu 退影子，拷回录进在录流、结束当前渲染编码器。
    //   期望（手算）：换编码器重绑 1 次、照常画出整屏 255 0 0 255（片元颜色 = U 前 16 字节 × 白贴图）。旧代码在已结束的编码器上设可见性 / 录绘制，SIGSEGV
    { printf("· 常量缓冲绑定同时读到待拷回段与 GPU 写在途段（退影子、切遍）：换编码器重绑 1 次、整屏画出 255 0 0 255、不崩\n");
      enum { UK = 4096 };
      static uint8_t z[2 * UK];
      uint32_t S = nxgal_buf_create(UK, 0), U = nxgal_buf_create(2 * UK, 0);
      nxgal_buf_set_data(S, 0, z, UK); nxgal_buf_set_data(U, 0, z, 2 * UK);
      gal_buf_read_gpu(U, 0, UK); nxgal_flush(); nxgal_create_sync(900, 1); nxgal_wait_sync(900);   // 交出过地址、GPU 做完：之后可建影子
      nxgal_set_render_targets(&g_rt, 1, 0); base_state(); clear_rt(0, 0, 0, 0); set_verts(k_quad, 4); nxgal_set_topology(7);
      gal_buf_read_gpu(U, 0, UK);                                   // 本次提交已用 [0, 4K)
      const float red[4] = {1, 0, 0, 1}; nxgal_buf_set_data(U, 0, red, 16);   // 命中已用：建影子、走镜像（待拷回段）
      gal_buf_read_gpu(U, UK, UK); nxgal_buf_copy(S, U, 0, UK, UK);  // GPU 写 [4K, 8K)，录在在录流
      nxgal_buf_assign a = {0, {U, 0, 2 * UK, 0}}; nxgal_set_uniform_buffers(&a, 1);
      uint64_t r0 = gal_rebind_n; nxgal_draw(4, 1, 0, 0);
      read_px(px); { uint8_t e[4] = {255, 0, 0, 255}; int n = count_px(px, e);
        CHECK(n == 1024 && gal_rebind_n == r0 + 1, "退影子切遍：期望重绑 1 次、1024 像素 255 0 0 255，实得重绑 %llu 次、%d 像素", (unsigned long long)(gal_rebind_n - r0), n); }
      nxgal_buf_delete(S); nxgal_buf_delete(U); }
    printf("· 四边形拓扑整屏：颜色 (0.2,0.4,0.6,1.0) × 白贴图 → 全部 51 102 153 255\n");
    nxgal_set_render_targets(&g_rt, 1, 0); base_state(); clear_rt(0, 0, 0, 0);
    set_color(0.2f, 0.4f, 0.6f, 1.0f); set_verts(k_quad, 4); nxgal_set_topology(7 /* Quads */);
    nxgal_draw(4, 1, 0, 0);
    read_px(px); { uint8_t e[4] = {51, 102, 153, 255}; int n = count_px(px, e); CHECK(n == 1024, "期望 1024 像素 = 51 102 153 255，实得 %d（(0,0) = %u %u %u %u）", n, px[0], px[1], px[2], px[3]); }

    // 占位贴图建不出（注入 gal_dummy_test_fail；本单测此前的绘制都绑了白贴图，占位贴图还没建）：贴图槽解绑后画 → 本次绘制跳过、不崩，
    //   目标保持清屏色 (10,20,30,40)；撤注入后同样画 → 占位贴图（全 0）× 颜色 = (0,0,0,0) 全 1024 像素（混合关，片元直接写）。
    //   旧代码反证：把 nil 贴图加进驻留集 / 往参数表填空资源号
    printf("· 占位贴图建不出（注入）：解绑贴图画 → 跳过、保持清屏色；撤注入后 → 全 0\n");
    { extern int gal_dummy_test_fail;
      nxgal_set_render_targets(&g_rt, 1, 0); base_state(); nxgal_set_texture_sampler(5, 0, 0, g_smp); clear_rt(10 / 255.0f, 20 / 255.0f, 30 / 255.0f, 40 / 255.0f);
      set_color(0.2f, 0.4f, 0.6f, 1.0f); set_verts(k_quad, 4); nxgal_set_topology(7);
      gal_dummy_test_fail = 1; nxgal_draw(4, 1, 0, 0); gal_dummy_test_fail = 0;
      read_px(px); { uint8_t e[4] = {10, 20, 30, 40}; int n = count_px(px, e); CHECK(n == 1024, "占位贴图建不出：期望 1024 像素保持 10 20 30 40，实得 %d（(0,0) = %u %u %u %u）", n, px[0], px[1], px[2], px[3]); }
      nxgal_draw(4, 1, 0, 0);
      read_px(px); { uint8_t e[4] = {0, 0, 0, 0}; int n = count_px(px, e); CHECK(n == 1024, "撤注入后：期望 1024 像素 = 0 0 0 0（占位贴图全 0），实得 %d（(0,0) = %u %u %u %u）", n, px[0], px[1], px[2], px[3]); }
      nxgal_set_texture_sampler(5, 0, g_white, g_smp); }

    // 正面判定：参照语义 = Ryujinx Vulkan 后端实际下发值：GAL FrontFace 取反（GAL CCW → VK CW，EnumConversion.cs）。
    // Vulkan 规范 25.7.1：a = -½ Σ (x_i y_{i+1} - x_{i+1} y_i)（帧缓冲坐标 y 朝下），VK CW 时 a < 0 为正面。
    // 规范化 (-1,-1),(1,-1),(-1,1) → 帧缓冲 (0,0),(32,0),(0,32)：Σ = 32·32 → a = -512 < 0 → 下发 VK CW（GAL CCW）时是正面。
    // 期望：剔正面 → 不画（0 像素）；剔背面 → 画（左上三角：只核两个明确点）
    printf("· 正面判定：三角 (-1,-1)(1,-1)(-1,1)，GAL 正面 = CCW（下发 VK CW）：剔正面 → 不画；剔背面 → 画\n");
    static const float tri[9] = {-1, -1, 0, 1, -1, 0, -1, 1, 0};
    clear_rt(0, 0, 0, 0); set_verts(tri, 3); nxgal_set_topology(4); set_color(1, 1, 1, 1);
    nxgal_set_face_culling(1, 0x404); nxgal_draw(3, 1, 0, 0);
    read_px(px); { uint8_t z[4] = {0, 0, 0, 0}; int n = count_px(px, z); CHECK(n == 1024, "剔正面：期望 1024 像素仍为 0，实得 %d", n); }
    clear_rt(0, 0, 0, 0); nxgal_set_face_culling(1, 0x405); nxgal_draw(3, 1, 0, 0);
    read_px(px); CHECK(px[(2 * 32 + 2) * 4] == 255, "剔背面：帧缓冲 (2,2)（左上）期望 255 实得 %u", px[(2 * 32 + 2) * 4]);
    CHECK(px[(29 * 32 + 29) * 4] == 0, "剔背面：帧缓冲 (29,29)（右下）期望 0 实得 %u", px[(29 * 32 + 29) * 4]);
    nxgal_set_face_culling(0, 0x405);

    // 负高度视口（Vulkan 的 Y 翻转写法，动森真局就是这样）：视口 (0,32) 32×-32 → 规范化 y=-1 落在帧缓冲 y=32（底），y=+1 落在 y=0（顶）。
    // 同一三角 (-1,-1)(1,-1)(-1,1) → 帧缓冲 (0,32),(32,32),(0,0)：Σ = -1024 → a = +512 > 0 → 帧缓冲里逆时针；下发 VK CW（GAL CCW）时是背面。
    // 期望：剔背面 → 不画；剔正面 → 画（左下三角：帧缓冲 (2,29) 有、(29,2) 无）
    printf("· 正面判定（负高度视口）：同一三角在 Y 翻转视口下变背面：剔背面 → 不画；剔正面 → 画\n");
    { nxgal_viewport vf = {0, 32, 32, -32, {0, 2, 4, 6}, 0, 1}; nxgal_set_viewports(&vf, 1);
      clear_rt(0, 0, 0, 0); set_verts(tri, 3); nxgal_set_topology(4); set_color(1, 1, 1, 1);
      nxgal_set_face_culling(1, 0x405); nxgal_draw(3, 1, 0, 0);
      read_px(px); { uint8_t z[4] = {0, 0, 0, 0}; int n = count_px(px, z); CHECK(n == 1024, "负高度视口剔背面：期望 1024 像素仍为 0，实得 %d", n); }
      clear_rt(0, 0, 0, 0); nxgal_set_face_culling(1, 0x404); nxgal_draw(3, 1, 0, 0);
      read_px(px); CHECK(px[(29 * 32 + 2) * 4] == 255, "负高度视口剔正面：帧缓冲 (2,29)（左下）期望 255 实得 %u", px[(29 * 32 + 2) * 4]);
      CHECK(px[(2 * 32 + 29) * 4] == 0, "负高度视口剔正面：帧缓冲 (29,2)（右上）期望 0 实得 %u", px[(2 * 32 + 29) * 4]);
      nxgal_set_face_culling(0, 0x405); nxgal_viewport vp = {0, 0, 32, 32, {0, 2, 4, 6}, 0, 1}; nxgal_set_viewports(&vp, 1); }

    // 3D 目标 + 顶点写层号：层号选深度切片（同 Vulkan 后端 3D 目标按 2D 数组视图挂、层数 = 深度）。原先 3D 恒按 1 层，层号被忽略、画进第 0 片（10-18 八方2 调色查找表）
    printf("· 3D 目标 32×32×2 + 顶点写层号 1：第 1 片全是 51 102 153 255、第 0 片保持清屏 0\n");
    { nxgal_tex_info vi = ti(32, 32, RGBA8, 4); vi.depth = 2; vi.target = 2; uint32_t v3 = nxgal_tex_create(&vi);
      nxgal_set_render_targets(&v3, 1, 0); base_state(); nxgal_set_program(g_lprog);
      float z4[4] = {0, 0, 0, 0}; nxgal_rect full = {0, 0, 0xffff, 0xffff}; nxgal_set_scissors(&full, 1); nxgal_clear_color(0, 0, 2, 0xf, z4);
      nxgal_rect sc = {0, 0, 32, 32}; nxgal_set_scissors(&sc, 1);
      set_color(0.2f, 0.4f, 0.6f, 1.0f); set_verts(k_quad, 4); nxgal_set_topology(7); nxgal_draw(4, 1, 0, 0);
      uint8_t s0[32 * 32 * 4], s1[32 * 32 * 4]; uint8_t e[4] = {51, 102, 153, 255}, z[4] = {0, 0, 0, 0};
      CHECK(nxgal_tex_get_data(v3, 1, 0, s1, sizeof s1) == sizeof s1 && count_px(s1, e) == 1024, "第 1 片期望 1024 像素 = 51 102 153 255，实得 %d", count_px(s1, e));
      CHECK(nxgal_tex_get_data(v3, 0, 0, s0, sizeof s0) == sizeof s0 && count_px(s0, z) == 1024, "第 0 片期望保持 0，实得 %d 像素为 0（(0,0) = %u %u %u %u）", count_px(s0, z), s0[0], s0[1], s0[2], s0[3]);
      nxgal_set_render_targets(&g_rt, 1, 0); nxgal_set_program(g_prog); nxgal_tex_release(v3); }

    printf("· 8 位索引 + 扇形拓扑（GPU 转换）：索引 0 1 2 3 画整屏 → 颜色 (0.4,0.4,0.4,0.4) = 102×4\n");
    clear_rt(0, 0, 0, 0); set_verts(k_quad, 4); set_color(0.4f, 0.4f, 0.4f, 0.4f);
    uint8_t idx8[4] = {0, 1, 2, 3}; g_ibuf = [dev newBufferWithBytes:idx8 length:4 options:MTLResourceStorageModeShared]; gal_res_add(g_ibuf);
    nxgal_buf_range ir = {stub_buf(g_ibuf), 0, 4, 0}; nxgal_set_index_buffer(&ir, 0); nxgal_set_topology(6 /* TriangleFan */);
    nxgal_draw_indexed(4, 1, 0, 0, 0);
    read_px(px); { uint8_t e[4] = {102, 102, 102, 102}; int n = count_px(px, e); CHECK(n == 1024, "期望 1024 像素 = 102×4，实得 %d（(0,0) = %u %u %u %u）", n, px[0], px[1], px[2], px[3]); }

    // 回归（10-18 塞尔达神庙第 717 次绘制）：16 位索引起点地址落在 2 字节处（区间偏移 2，或起始索引为奇数），Metal 直接读出的三角形不对。
    // 索引 [FFFF, 0 1 2, 0 2 3] 两个三角形铺满四边形：两种起点都应整屏 1024 像素 = 颜色
    printf("· 16 位索引起点不在 4 字节对齐处（区间偏移 2 / 起始索引 1）：两个三角形铺满整屏\n");
    { uint16_t idx16[8] = {0xFFFF, 0, 1, 2, 0, 2, 3, 0xFFFF};
      id<MTLBuffer> ib16 = [dev newBufferWithBytes:idx16 length:sizeof idx16 options:MTLResourceStorageModeShared]; gal_res_add(ib16);
      uint32_t ibh = stub_buf(ib16); nxgal_set_topology(4 /* Triangles */); set_color(0.4f, 0.4f, 0.4f, 0.4f);
      clear_rt(0, 0, 0, 0); nxgal_buf_range r2 = {ibh, 2, 12, 0}; nxgal_set_index_buffer(&r2, 1); nxgal_draw_indexed(6, 1, 0, 0, 0);
      read_px(px); { uint8_t e[4] = {102, 102, 102, 102}; int n = count_px(px, e); CHECK(n == 1024, "区间偏移 2：期望 1024 像素 = 102×4，实得 %d", n); }
      clear_rt(0, 0, 0, 0); nxgal_buf_range r0 = {ibh, 0, 16, 0}; nxgal_set_index_buffer(&r0, 1); nxgal_draw_indexed(6, 1, 1, 0, 0);
      read_px(px); { uint8_t e[4] = {102, 102, 102, 102}; int n = count_px(px, e); CHECK(n == 1024, "起始索引 1：期望 1024 像素 = 102×4，实得 %d", n); } }

    // 间接计数绘制（同 vkCmdDrawIndexedIndirectCount）：实际条数 = min(计数, 上限)。参数步长 32 字节（不紧排），索引 [0 1 2, 0 2 3]：
    // e0 = 三角 (0,1,2) 半屏、e1 = 三角 (0,2,3) 另半屏、e2 同 e0。期望：计数 1 / 上限 3 → 半屏（对角线 32 像素归属按光栅规则，496–528）；
    // 计数 5 / 上限 2 → 截到 2 条 → 整屏 1024；计数 0 → 0
    printf("· 间接计数索引绘制：计数 1 → 半屏，计数 5 上限 2 → 整屏，计数 0 → 不画\n");
    { uint16_t idx6[6] = {0, 1, 2, 0, 2, 3};
      id<MTLBuffer> ib6 = [dev newBufferWithBytes:idx6 length:sizeof idx6 options:MTLResourceStorageModeShared]; gal_res_add(ib6);
      nxgal_buf_range r6 = {stub_buf(ib6), 0, 12, 0}; nxgal_set_index_buffer(&r6, 1); nxgal_set_topology(4 /* Triangles */); set_color(0.4f, 0.4f, 0.4f, 0.4f);
      uint32_t args[3][8] = {{3, 1, 0, 0, 0}, {3, 1, 3, 0, 0}, {3, 1, 0, 0, 0}};
      id<MTLBuffer> ab = [dev newBufferWithBytes:args length:sizeof args options:MTLResourceStorageModeShared]; gal_res_add(ab);
      nxgal_buf_range ar = {stub_buf(ab), 0, sizeof args, 0};
      uint32_t cnts[3] = {1, 5, 0}; int maxs[3] = {3, 2, 3}; uint8_t e[4] = {102, 102, 102, 102};
      for (int k = 0; k < 3; k++) {
        id<MTLBuffer> cb = [dev newBufferWithBytes:&cnts[k] length:4 options:MTLResourceStorageModeShared]; gal_res_add(cb);
        nxgal_buf_range cr = {stub_buf(cb), 0, 4, 0};
        clear_rt(0, 0, 0, 0); nxgal_draw_indirect_count(&ar, &cr, maxs[k], 32, 1);
        read_px(px); int n = count_px(px, e);
        if (k == 0) CHECK(n >= 496 && n <= 528, "计数 1 / 上限 3：期望半屏 496–528 像素，实得 %d", n);
        if (k == 1) CHECK(n == 1024, "计数 5 / 上限 2：期望整屏 1024 像素，实得 %d", n);
        if (k == 2) CHECK(n == 0, "计数 0：期望 0 像素，实得 %d", n);
      } }

    // 回归（10-19 怪猎崛起语言页斜向乱三角）：未对齐的 16 位索引转 32 位时，条带里的重启标记 0xFFFF 被零扩成顶点 65535。
    // 条带 [0 1 2, FFFF, 3 4 5]：左下、右下各一个小三角；顶点 65535 放在右上角——重启没保住就会连出跨过屏幕中心的大三角
    printf("· 16 位条带 + 图元重启 + 区间偏移 2（转 32 位要保住重启）：只画两个角上的小三角，中心保持 0\n");
    { float *vv = calloc(65536 * 3, sizeof *vv);
      const float corner[18] = {-1, -1, 0, -0.5f, -1, 0, -1, -0.5f, 0,   1, -1, 0, 1, -0.5f, 0, 0.5f, -1, 0};
      memcpy(vv, corner, sizeof corner); vv[65535 * 3] = 1; vv[65535 * 3 + 1] = 1;
      set_verts(vv, 65536); free(vv);
      uint16_t idx16[9] = {0xFFFF, 0, 1, 2, 0xFFFF, 3, 4, 5, 0xFFFF};
      id<MTLBuffer> ib16 = [dev newBufferWithBytes:idx16 length:sizeof idx16 options:MTLResourceStorageModeShared]; gal_res_add(ib16);
      nxgal_buf_range r2 = {stub_buf(ib16), 2, 14, 0}; nxgal_set_index_buffer(&r2, 1); nxgal_set_topology(5 /* TriangleStrip */); nxgal_set_primitive_restart(1, 0xffff);
      clear_rt(0, 0, 0, 0); set_color(0.4f, 0.4f, 0.4f, 0.4f); nxgal_draw_indexed(7, 1, 0, 0, 0);
      read_px(px); { uint8_t e[4] = {102, 102, 102, 102}, z[4] = {0, 0, 0, 0}; int n = count_px(px, e);
        CHECK(!memcmp(px + (16 * 32 + 16) * 4, z, 4), "中心 (16,16) 期望 0（重启被当成顶点 65535 会连出大三角）实得 %u %u %u %u", px[(16*32+16)*4], px[(16*32+16)*4+1], px[(16*32+16)*4+2], px[(16*32+16)*4+3]);
        CHECK(n >= 40 && n <= 120, "两个角上小三角共约 64 像素，实得 %d", n); }
      set_verts(k_quad, 4); nxgal_set_topology(4 /* Triangles */); }

    // 关图元重启（10-23 图形接口盘点静默 3：开关只记不读）：条带里的全 1 是普通顶点号，不能当重启。
    // 顶点 0 (-1,-1)、1 (3,-1)、65535 和 255 放 (-1,3)：条带 [0 1 全1] 就是一个盖满整屏的大三角（1024 像素）；当成重启则一个三角也没有（0 像素）。
    // 三种走法：16 位对齐（原生 16 位路径）、16 位区间偏移 2（转 32 位缓存）、8 位（转 32 位）；末了开重启复核同一条带画 0 像素（重启语义不受影响）
    printf("· 关图元重启：16 位 / 16 位偏移 2 / 8 位条带里的全 1 是顶点 65535 / 255 → 整屏；开重启 → 不画\n");
    { float *vv = calloc(65536 * 3, sizeof *vv);
      vv[0] = -1; vv[1] = -1; vv[3] = 3; vv[4] = -1; vv[65535 * 3] = -1; vv[65535 * 3 + 1] = 3; vv[255 * 3] = -1; vv[255 * 3 + 1] = 3;
      set_verts(vv, 65536); free(vv);
      uint16_t i16[4] = {0, 1, 0xFFFF, 0}; uint16_t i16o[4] = {0, 0, 1, 0xFFFF}; uint8_t i8[4] = {0, 1, 0xFF, 0};
      id<MTLBuffer> b16 = [dev newBufferWithBytes:i16 length:8 options:MTLResourceStorageModeShared], b16o = [dev newBufferWithBytes:i16o length:8 options:MTLResourceStorageModeShared],
                    b8 = [dev newBufferWithBytes:i8 length:4 options:MTLResourceStorageModeShared];
      gal_res_add(b16); gal_res_add(b16o); gal_res_add(b8);
      struct { const char *nm; uint32_t buf; int off, size, type; } cs[3] = {{"16 位对齐", stub_buf(b16), 0, 6, 1}, {"16 位区间偏移 2", stub_buf(b16o), 2, 6, 1}, {"8 位", stub_buf(b8), 0, 3, 0}};
      nxgal_set_topology(5 /* TriangleStrip */); set_color(0.4f, 0.4f, 0.4f, 0.4f); uint8_t e[4] = {102, 102, 102, 102};
      for (int k = 0; k < 3; k++) {
        nxgal_buf_range r = {cs[k].buf, cs[k].off, cs[k].size, 0}; nxgal_set_index_buffer(&r, cs[k].type);
        nxgal_set_primitive_restart(0, cs[k].type == 0 ? 0xff : 0xffff); clear_rt(0, 0, 0, 0); nxgal_draw_indexed(3, 1, 0, 0, 0);
        read_px(px); int n = count_px(px, e); CHECK(n == 1024, "关重启 %s：全 1 当顶点 → 期望整屏 1024 像素，实得 %d（当成重启就是 0）", cs[k].nm, n);
        nxgal_set_primitive_restart(1, cs[k].type == 0 ? 0xff : 0xffff); clear_rt(0, 0, 0, 0); nxgal_draw_indexed(3, 1, 0, 0, 0);
        read_px(px); n = count_px(px, e); CHECK(n == 0, "开重启 %s：同一条带 → 期望 0 像素，实得 %d", cs[k].nm, n);
      }
      // CPU 读不到索引（GPU 拷进来、还在在录命令缓冲里）→ 直接绘制走 GPU 整段零扩缓存；间接绘制走 ib_norestart32
      uint32_t gsrc = nxgal_buf_create(8, 0), gib = nxgal_buf_create(8, 0); nxgal_buf_set_data(gsrc, 0, i16, 8);
      uint32_t prm[5] = {3, 1, 0, 0, 0}; uint32_t ind = nxgal_buf_create(20, 0); nxgal_buf_set_data(ind, 0, prm, 20); nxgal_buf_range ir = {ind, 0, 20, 0};
      for (int k = 0; k < 2; k++) {
        nxgal_buf_copy(gsrc, gib, 0, 0, 8); nxgal_buf_range r = {gib, 0, 8, 0}; nxgal_set_index_buffer(&r, 1);
        nxgal_set_primitive_restart(0, 0xffff); clear_rt(0, 0, 0, 0);
        if (k == 0) nxgal_draw_indexed(3, 1, 0, 0, 0); else nxgal_draw_indirect(&ir, 1);
        read_px(px); int n = count_px(px, e);
        CHECK(n == 1024, "关重启 16 位%s：全 1 当顶点 → 期望整屏 1024 像素，实得 %d（当成重启就是 0）", k ? "间接绘制" : " CPU 读不到（GPU 写入）", n);
      }
      nxgal_set_primitive_restart(1, 0xffff); set_verts(k_quad, 4); nxgal_set_topology(4 /* Triangles */); }

    // 回归（10-20 画幅线：丝之歌每帧现写顶点的精灵整批不画）：镜像读按「本次提交 + 区间」缓存且不登记已用区间，
    // 紧跟的写走预载分支时旧代码不作废重叠镜像，下一次绘制读到写前内容。期望：最后一次画 B 段（写成全屏四边形）→ 整屏 1024 像素红
    printf("· 镜像过期：写入后紧跟的绘制必须读到新顶点（B 段全零 → 写成全屏四边形 → 整屏红）\n");
    { float v[24] = {-1, -1, 0, 1, -1, 0, 1, 1, 0, -1, 1, 0};   // A 段：全屏四边形；B 段：全零（退化，画不出）
      uint32_t vb = nxgal_buf_create(96, 0); nxgal_buf_set_data(vb, 0, v, 96);
      nxgal_vattr at = {0, 0, 0, 33}; nxgal_set_vertex_attribs(&at, 1); nxgal_set_topology(7 /* Quads */);
      nxgal_vbuf ra = {{vb, 0, 48, 0}, 12, 0}, rab = {{vb, 0, 96, 0}, 12, 0};
      clear_rt(0, 0, 0, 0); set_color(0, 1, 0, 1); nxgal_set_vertex_buffers(&ra, 1); nxgal_draw(4, 1, 0, 0);   // 让缓冲被 GPU 用过
      nxgal_flush();
      nxgal_set_vertex_buffers(&ra, 1); nxgal_draw(4, 1, 0, 0);                         // 本次提交用 A 段
      nxgal_buf_set_data(vb, 0, v, 48);                                                 // 写 A：命中已用区间 → 镜像分支（建影子、记待拷回）
      nxgal_set_vertex_buffers(&rab, 1); nxgal_draw(4, 1, 4, 0);                        // 绑 A+B 画 B：区间含待拷回 → 建镜像并缓存（B 全零，不画）
      nxgal_buf_set_data(vb, 48, v, 48);                                                // 写 B = 全屏四边形：B 本次没用过 → 预载分支
      clear_rt(0, 0, 0, 0); set_color(1, 0, 0, 1); nxgal_set_vertex_buffers(&rab, 1); nxgal_draw(4, 1, 4, 0);
      read_px(px); { uint8_t e[4] = {255, 0, 0, 255}; int n = count_px(px, e); CHECK(n == 1024, "镜像过期：期望 1024 像素红，实得 %d", n); }
      nxgal_buf_delete(vb); set_verts(k_quad, 4); }

    printf("· 深度：清 0.5，z=0.25 绿（Less 过）、再 z=0.75 红（Less 不过）→ 全绿\n");
    nxgal_set_render_targets(&g_rt, 1, g_ds); clear_rt(0, 0, 0, 0); nxgal_clear_ds(0, 1, 0.5f, 1, 0, 0);
    nxgal_depth_test dt = {1, 1, 2 /* Less */}; nxgal_set_depth_test(&dt); nxgal_set_topology(7);
    static const float q25[12] = {-1, -1, 0.25f, 1, -1, 0.25f, 1, 1, 0.25f, -1, 1, 0.25f}, q75[12] = {-1, -1, 0.75f, 1, -1, 0.75f, 1, 1, 0.75f, -1, 1, 0.75f};
    set_verts(q25, 4); set_color(0, 1, 0, 1); nxgal_draw(4, 1, 0, 0);
    set_verts(q75, 4); set_color(1, 0, 0, 1); nxgal_draw(4, 1, 0, 0);
    read_px(px); { uint8_t e[4] = {0, 255, 0, 255}; int n = count_px(px, e); CHECK(n == 1024, "期望 1024 像素绿，实得 %d（(0,0) = %u %u %u %u）", n, px[0], px[1], px[2], px[3]); }
    float dpx[1024]; nxgal_tex_get_data(g_ds, 0, 0, dpx, sizeof dpx); CHECK(dpx[0] == 0.25f && dpx[1023] == 0.25f, "深度期望 0.25 实得 %g / %g", dpx[0], dpx[1023]);
    // 同上换 D24UnormS8Uint 深度附件（Metal 里是 Depth32Float_Stencil8 两平面；画幅线 10-20 报暗黑3 场景深度读回全 1.0）。
    // 期望：读回按 d24 << 8 | s，d24 = round(0.25 × (2²⁴ − 1)) = round(4194303.75) = 4194304 → 0x40000000（模板清 0）
    printf("· 深度 D24S8：清 0.5 / 模板 0，z=0.25 绿 → 读回每像素 0x40000000\n");
    { nxgal_tex_info d24i = ti(32, 32, 52 /* D24UnormS8Uint */, 4); uint32_t d24 = nxgal_tex_create(&d24i);
      nxgal_set_render_targets(&g_rt, 1, d24); clear_rt(0, 0, 0, 0); nxgal_clear_ds(0, 1, 0.5f, 1, 0, 0xff);
      nxgal_set_depth_test(&dt); set_verts(q25, 4); set_color(0, 1, 0, 1); nxgal_draw(4, 1, 0, 0);
      read_px(px); { uint8_t e[4] = {0, 255, 0, 255}; int n = count_px(px, e); CHECK(n == 1024, "D24S8：期望 1024 像素绿，实得 %d", n); }
      uint32_t dv[1024]; nxgal_tex_get_data(d24, 0, 0, dv, sizeof dv); int ok = 0; for (int k = 0; k < 1024; k++) ok += dv[k] == 0x40000000u;
      CHECK(ok == 1024, "D24S8 深度读回：期望 1024 个 0x40000000，实得 %d 个（[0] = %08x、[1023] = %08x）", ok, dv[0], dv[1023]);
      nxgal_set_render_targets(&g_rt, 1, g_ds); nxgal_tex_release(d24); }
    nxgal_depth_test off = {0, 0, 8}; nxgal_set_depth_test(&off); nxgal_set_render_targets(&g_rt, 1, 0);

    printf("· 混合 SrcAlpha / OneMinusSrcAlpha：目标清 0，画 (1,0,0,0.4) → R 102、A round(0.16×255=40.8)=41\n");
    clear_rt(0, 0, 0, 0); set_verts(k_quad, 4); set_color(1, 0, 0, 0.4f);
    nxgal_blend bl = {1, {0, 0, 0, 0}, 1, 5, 6, 1, 5, 6}; nxgal_set_blend(0, &bl);
    nxgal_draw(4, 1, 0, 0);
    read_px(px); CHECK(px[0] == 102 && px[1] == 0 && px[2] == 0 && px[3] == 41, "期望 102 0 0 41 实得 %u %u %u %u", px[0], px[1], px[2], px[3]);
    nxgal_blend nb = {0, {0, 0, 0, 0}, 1, 2, 1, 1, 2, 1}; nxgal_set_blend(0, &nb);

    printf("· 剪裁 (4,4,8,8) + 写掩码只开 G：清 (0.2,0.2,0.2,0.2)，画白 → 框内 51 255 51 51，框外 51×4\n");
    clear_rt(0.2f, 0.2f, 0.2f, 0.2f); set_color(1, 1, 1, 1);
    uint32_t mg[8] = {2, 0xf, 0xf, 0xf, 0xf, 0xf, 0xf, 0xf}; nxgal_set_color_masks(mg, 8);
    nxgal_rect sc = {4, 4, 8, 8}; nxgal_set_scissors(&sc, 1);
    nxgal_draw(4, 1, 0, 0);
    read_px(px); { uint8_t in[4] = {51, 255, 51, 51}, out[4] = {51, 51, 51, 51}; int a = count_px(px, in), b = count_px(px, out);
        CHECK(a == 64 && b == 1024 - 64, "期望框内 64 / 框外 960，实得 %d / %d", a, b);
        CHECK(!memcmp(px + (4 * 32 + 4) * 4, in, 4) && !memcmp(px + (12 * 32 + 12) * 4, out, 4), "(4,4) 应在框内、(12,12) 应在框外"); }
    uint32_t mall[8] = {0xf, 0xf, 0xf, 0xf, 0xf, 0xf, 0xf, 0xf}; nxgal_set_color_masks(mall, 8);
    nxgal_rect full = {0, 0, 32, 32}; nxgal_set_scissors(&full, 1);

    printf("· DrawTexture：2×2 贴图（红 绿 / 蓝 白）最近邻放大到 (0,0)-(32,32)：四个象限各一色\n");
    { nxgal_tex_info si = ti(2, 2, RGBA8, 4); uint32_t st = nxgal_tex_create(&si);
      uint8_t texels[16] = {255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255}; nxgal_tex_set_data(st, 0, 0, NULL, texels, 16);
      clear_rt(0, 0, 0, 0); float sr[4] = {0, 0, 2, 2}, dr[4] = {0, 0, 32, 32};
      nxgal_draw_texture(st, g_smp, sr, dr); read_px(px);
      CHECK(!memcmp(px + (4 * 32 + 4) * 4, texels, 4), "(4,4) 期望红 实得 %u %u %u %u", px[(4*32+4)*4], px[(4*32+4)*4+1], px[(4*32+4)*4+2], px[(4*32+4)*4+3]);
      CHECK(!memcmp(px + (4 * 32 + 28) * 4, texels + 4, 4), "(28,4) 期望绿");
      CHECK(!memcmp(px + (28 * 32 + 4) * 4, texels + 8, 4), "(4,28) 期望蓝");
      CHECK(!memcmp(px + (28 * 32 + 28) * 4, texels + 12, 4), "(28,28) 期望白");
      // 目标矩形左右反向 (32,0)-(0,32)：水平镜像，(4,4) 应为绿
      clear_rt(0, 0, 0, 0); float dm[4] = {32, 0, 0, 32}; nxgal_draw_texture(st, g_smp, sr, dm); read_px(px);
      CHECK(!memcmp(px + (4 * 32 + 4) * 4, texels + 4, 4), "镜像后 (4,4) 期望绿");
      nxgal_set_program(g_prog); }

    printf("· 回归（动森真局 10-18）：顶点着色器写点大小 + 三角形拓扑；另挂一个无 Metal 顶点格式的属性在单独缓冲上 → 照常画、不崩\n");
    { static gal_prog Q; Q = P; Q.fn[1] = fn(lib, @"vs_ps"); Q.vs_point_size = 1; Q.vs_inputs = 0x3; Q.hash = 0x3333; uint32_t qid = stub_prog(&Q);
      clear_rt(0, 0, 0, 0); set_verts(k_quad, 4); set_color(0.2f, 0.4f, 0.6f, 1.0f); nxgal_set_topology(7); nxgal_set_program(qid);
      // 属性 1：R10G10B10A2Uint（Metal 无此顶点格式）挂在缓冲 1（只有它引用缓冲 1）
      nxgal_vattr at[2] = {{0, 0, 0, 33}, {1, 0, 0, 61}}; nxgal_set_vertex_attribs(at, 2);
      nxgal_draw(4, 1, 0, 0); read_px(px);
      { uint8_t e[4] = {51, 102, 153, 255}; int n = count_px(px, e); CHECK(n == 1024, "期望 1024 像素 = 51 102 153 255，实得 %d", n); }
      nxgal_set_program(g_prog); }

    printf("· 顶点跨度 13（不是 4 的倍数，走计算着色器重排）：整屏四边形 → 全部 51 102 153 255\n");
    { uint8_t vb13[13 * 4]; for (int k = 0; k < 4; k++) { memcpy(vb13 + 13 * k, k_quad + 3 * k, 12); vb13[13 * k + 12] = 0xEE; }
      id<MTLBuffer> v = [dev newBufferWithBytes:vb13 length:sizeof vb13 options:MTLResourceStorageModeShared];
      nxgal_vbuf vb = {{stub_buf(v), 0, (int32_t)sizeof vb13, 0}, 13, 0}; nxgal_set_vertex_buffers(&vb, 1);
      nxgal_vattr at = {0, 0, 0, 33}; nxgal_set_vertex_attribs(&at, 1);
      clear_rt(0, 0, 0, 0); set_color(0.2f, 0.4f, 0.6f, 1.0f); nxgal_set_topology(7); nxgal_set_program(g_prog);
      nxgal_draw(4, 1, 0, 0); read_px(px);
      { uint8_t e[4] = {51, 102, 153, 255}; int n = count_px(px, e); CHECK(n == 1024, "跨度 13：期望 1024 像素，实得 %d", n); }
      // 重排缓存建不出（注入）：新缓冲（缓存不命中）→ 本次绘制跳过、目标保持 0；撤注入后同样绘制全部 51 102 153 255。
      // 旧代码反证：取不到重排缓存时照常画、按未重排的跨度读顶点（非自取路径绑定跨度向上取 16），目标不保持 0
      printf("· 顶点重排缓存建不出（注入）：绘制跳过、目标保持 0；撤注入后照常\n");
      id<MTLBuffer> v2 = [dev newBufferWithBytes:vb13 length:sizeof vb13 options:MTLResourceStorageModeShared];
      nxgal_vbuf vb2 = {{stub_buf(v2), 0, (int32_t)sizeof vb13, 0}, 13, 0}; nxgal_set_vertex_buffers(&vb2, 1);
      clear_rt(0, 0, 0, 0);
      gal_newbuf_test_fail = 1; nxgal_draw(4, 1, 0, 0); gal_newbuf_test_fail = 0;
      read_px(px); { uint8_t z[4] = {0, 0, 0, 0}; int n = count_px(px, z); CHECK(n == 1024, "重排缓存建不出：期望 1024 像素保持 0，实得 %d", n); }
      nxgal_draw(4, 1, 0, 0); read_px(px);
      { uint8_t e[4] = {51, 102, 153, 255}; int n = count_px(px, e); CHECK(n == 1024, "撤注入后跨度 13：期望 1024 像素，实得 %d", n); } }

    // 重排缓存随 GPU 写作废（清单 #9）：顶点缓冲 X（跨度 13，走重排）同时被计算着色器 cs_flip 当可写存储缓冲（每次把 4 个顶点的 x 取反）。
    // 同一次提交内：派发（整块写参数集）→ 画 → 再派发（参数集照用，不再取址）→ 画。X 初值 = 左半屏四边形 x∈[-1,0]：
    // 第一次派发后 X = 右半屏，第一次画右半 512 像素；第二次派发后 X = 左半屏，第二次画必须读到新 X → 两次合计整屏 1024 像素。
    // 旧代码：第二次派发参数集照用、不经缓冲取址，重排缓存不作废，第二次画仍读右半 → 只有 512 像素
    printf("· 顶点重排缓存随存储缓冲写作废：派发 → 画 → 派发（参数集照用）→ 画，两次合计整屏 1024 像素\n");
    { static const float half[12] = {-1, -1, 0, 0, -1, 0, 0, 1, 0, -1, 1, 0};
      uint8_t xb[13 * 4]; for (int k = 0; k < 4; k++) { memcpy(xb + 13 * k, half + 3 * k, 12); xb[13 * k + 12] = 0xEE; }
      id<MTLBuffer> xm = [dev newBufferWithBytes:xb length:sizeof xb options:MTLResourceStorageModeShared]; uint32_t xid = stub_buf(xm);
      static gal_prog F; F = C; F.fn[0] = fn(lib, @"cs_flip"); F.hash = 0x4444; uint32_t fid = stub_prog(&F);
      nxgal_set_render_targets(&g_rt, 1, 0); base_state(); set_color(0.2f, 0.4f, 0.6f, 1.0f); nxgal_set_topology(7);
      nxgal_vbuf xv = {{xid, 0, (int32_t)sizeof xb, 0}, 13, 0}; nxgal_set_vertex_buffers(&xv, 1);
      nxgal_vattr at = {0, 0, 0, 33}; nxgal_set_vertex_attribs(&at, 1);
      nxgal_buf_assign xs = {0, {xid, 0, (int32_t)sizeof xb, 1}}; nxgal_set_storage_buffers(&xs, 1);
      clear_rt(0, 0, 0, 0); read_px(px);
      nxgal_set_program(fid); nxgal_dispatch(1, 1, 1);
      nxgal_set_program(g_prog); nxgal_draw(4, 1, 0, 0);
      nxgal_set_program(fid); nxgal_dispatch(1, 1, 1);
      nxgal_set_program(g_prog); nxgal_draw(4, 1, 0, 0);
      read_px(px); { uint8_t e[4] = {51, 102, 153, 255}; int n = count_px(px, e); CHECK(n == 1024, "存储缓冲写后重排：期望 1024 像素（左右两半各画一次），实得 %d", n); }
      nxgal_buf_assign none = {0, {0, 0, 0, 0}}; nxgal_set_storage_buffers(&none, 1); }

    // 同上，写法换成图像缓冲（R8Uint 贴图缓冲挂在 X 上，计算着色器 imageStore 逐字节写右半屏四边形）：画（重排缓存 = 左半）→ 派发写 → 画 → 合计 1024。
    // 旧代码：图像缓冲的写从不作废重排缓存（只在 SetStorage 取址那一次），第二次画仍读左半 → 512
    printf("· 顶点重排缓存随图像缓冲写作废：画（左半）→ 图像缓冲派发写右半 → 画，合计整屏 1024 像素\n");
    { static const float half[12] = {-1, -1, 0, 0, -1, 0, 0, 1, 0, -1, 1, 0};
      uint8_t xb[64]; memset(xb, 0, sizeof xb); for (int k = 0; k < 4; k++) { memcpy(xb + 13 * k, half + 3 * k, 12); xb[13 * k + 12] = 0xEE; }
      id<MTLBuffer> xm = [dev newBufferWithBytes:xb length:sizeof xb options:MTLResourceStorageModeShared]; uint32_t xid = stub_buf(xm);
      nxgal_tex_info bi = ti(52, 1, 2 /* R8Uint */, 1); bi.target = 9; uint32_t tb = nxgal_tex_create(&bi);
      nxgal_buf_range tr = {xid, 0, 52, 1}; nxgal_tex_set_storage(tb, &tr);
      static gal_arg iargs[1] = {{GAL_ARG_BUFIMG, 1, 0, 0, 1, 1u << 0}};
      static gal_prog G; G = C; G.fn[0] = fn(lib, @"cs_img"); G.args = iargs; G.hash = 0x5555; uint32_t gid = stub_prog(&G);
      nxgal_set_render_targets(&g_rt, 1, 0); base_state(); set_color(0.2f, 0.4f, 0.6f, 1.0f); nxgal_set_topology(7);
      nxgal_vbuf xv = {{xid, 0, 52, 0}, 13, 0}; nxgal_set_vertex_buffers(&xv, 1);
      nxgal_vattr at = {0, 0, 0, 33}; nxgal_set_vertex_attribs(&at, 1);
      nxgal_set_image(0, 0, tb);
      clear_rt(0, 0, 0, 0); read_px(px);
      nxgal_set_program(g_prog); nxgal_draw(4, 1, 0, 0);
      nxgal_set_program(gid); nxgal_dispatch(2, 1, 1);
      nxgal_set_program(g_prog); nxgal_draw(4, 1, 0, 0);
      read_px(px); { uint8_t e[4] = {51, 102, 153, 255}; int n = count_px(px, e); CHECK(n == 1024, "图像缓冲写后重排：期望 1024 像素（左右两半各画一次），实得 %d", n); }
      nxgal_set_image(0, 0, 0); nxgal_tex_release(tb); }

    printf("· 计算派发：64 线程（2 组 × 32）写 out[g] = 3g + 7\n");
    g_sbuf = [dev newBufferWithLength:64 * 4 options:MTLResourceStorageModeShared]; memset(g_sbuf.contents, 0, 256); gal_res_add(g_sbuf);
    uint32_t sb = stub_buf(g_sbuf);
    nxgal_buf_assign sa = {0, {sb, 0, 256, 1}}; nxgal_set_storage_buffers(&sa, 1);
    nxgal_set_program(g_cprog); nxgal_dispatch(2, 1, 1);
    uint32_t o[64]; CHECK(nxgal_buf_get_data(sb, 0, 256, o) == 0, "读回存储缓冲失败"); int bad = 0; for (int i = 0; i < 64; i++) bad += o[i] != (uint32_t)(i * 3 + 7);
    CHECK(!bad, "期望 64 个值全对，错 %d（o[0]=%u o[63]=%u）", bad, o[0], o[63]);

    // 同一绑定号上的普通贴图与贴图缓冲互不覆盖（同 Ryujinx Vulkan DescriptorSetUpdater 两张表；10-22 八方2 酒馆全暗：色调映射顶点着色器
    //   绑定 0 的 1×1 曝光贴图被同绑定号的贴图缓冲顶掉，曝光读成 0）。计算着色器同时读绑定 0 的 2D 贴图 A（1×1 R32F = 3.5）与贴图缓冲 B（R32F × 4 = 5 6 7 8）。
    //   期望（手算）：先绑 A 再绑 B、先清（置 0 两张都清，同 Vulkan 传 null）再绑 B 再绑 A 两种次序都读出 out = {3.5, 4, 8}。
    //   旧代码：一张表，后绑的顶掉先绑的 → 先 A 后 B 时 out[0] 读不到 3.5，先 B 后 A 时 out[1] / out[2] 读不到 4 / 8
    printf("· 同一绑定号的普通贴图与贴图缓冲各占一张表：两种绑定次序都读出 3.5 / 宽 4 / 8\n");
    { nxgal_tex_info ai = ti(1, 1, R32F, 4); uint32_t A = nxgal_tex_create(&ai); float av = 3.5f; nxgal_tex_set_data(A, 0, 0, NULL, &av, 4);
      id<MTLBuffer> bm = [dev newBufferWithLength:16 options:MTLResourceStorageModeShared]; float bv[4] = {5, 6, 7, 8}; memcpy(bm.contents, bv, 16); uint32_t bid = stub_buf(bm);
      nxgal_tex_info bi = ti(4, 1, R32F, 4); bi.target = 9; uint32_t B = nxgal_tex_create(&bi);
      nxgal_buf_range br = {bid, 0, 16, 0}; nxgal_tex_set_storage(B, &br);
      static gal_arg targs[3] = {{GAL_ARG_TEX, 1, 0, 0, 1, 1u << 0}, {GAL_ARG_BUFTEX, 1, 0, 8, 1, 1u << 0}, {GAL_ARG_SSBO, 1, 0, 16, 1, 1u << 0}};
      static gal_prog TB; TB = C; TB.fn[0] = fn(lib, @"cs_tb"); TB.args = targs; TB.nargs = 3; TB.set_size[1] = 24; TB.stage_set_size[0][1] = 24; TB.hash = 0x6666;
      uint32_t tbp = stub_prog(&TB);
      id<MTLBuffer> om = [dev newBufferWithLength:16 options:MTLResourceStorageModeShared]; memset(om.contents, 0, 16); uint32_t oid = stub_buf(om);
      nxgal_buf_assign oa = {0, {oid, 0, 16, 1}}; nxgal_set_storage_buffers(&oa, 1);
      for (int order = 0; order < 2; order++) {
          if (order == 0) { nxgal_set_texture_sampler(0, 0, A, 0); nxgal_set_texture_sampler(0, 0, B, 0); }
          else { nxgal_set_texture_sampler(0, 0, 0, 0); nxgal_set_texture_sampler(0, 0, B, 0); nxgal_set_texture_sampler(0, 0, A, 0); }
          float z[4] = {0}; nxgal_buf_set_data(oid, 0, z, 16);
          nxgal_set_program(tbp); nxgal_dispatch(1, 1, 1);
          float r[4]; CHECK(nxgal_buf_get_data(oid, 0, 16, r) == 0, "读回失败");
          CHECK(r[0] == 3.5f && r[1] == 4 && r[2] == 8, "%s：期望 2D 贴图 3.5、贴图缓冲宽 4 第 3 项 8，实得 %g / %g / %g", order ? "先贴图缓冲后 2D" : "先 2D 后贴图缓冲", r[0], r[1], r[2]);
      }
      nxgal_set_texture_sampler(0, 0, 0, 0);
      nxgal_buf_assign none = {0, {0, 0, 0, 0}}; nxgal_set_storage_buffers(&none, 1);
      nxgal_tex_release(A); nxgal_tex_release(B); }

    // 无附件绘制（10-21 怪猎 mhrise_1021215739_2「开渲染通道时没有任何附件（无目标绘制，宽高按 1）」）：目标组为空，片元只做原子加 1（只靠副作用）。
    //   期望（手算，不跑被测实现）：整屏三角盖满视口，片元数 = 视口像素数。① 视口 / 剪裁 24×20 → 480；② 同一通道里视口 / 剪裁改 40×30 → 再 +1200（通道须按新视口重开）
    //   反证（旧代码宽高按 1、剪裁钳成 1×1）：① 1、② 1
    printf("· 无附件绘制：片元原子计数 = 视口像素数（24×20 → 480，再 40×30 → +1200）\n");
    { static gal_arg ta[1] = {{GAL_ARG_SSBO, 1, 0, 0, 1, 1u << 5}};
      static gal_prog T; T = P; T.fn[5] = fn(lib, @"fs_tl"); T.args = ta; T.nargs = 1; T.fs_outputs = 0; T.hash = 0x5555;
      memset(T.set_size, 0, sizeof T.set_size); memset(T.set_stages, 0, sizeof T.set_stages); memset(T.stage_set_size, 0, sizeof T.stage_set_size);
      T.set_size[1] = 8; T.set_stages[1] = 1u << 5; T.stage_set_size[5][1] = 8;
      uint32_t tp = stub_prog(&T);
      id<MTLBuffer> cb = [dev newBufferWithLength:16 options:MTLResourceStorageModeShared]; memset(cb.contents, 0, 16); gal_res_add(cb); uint32_t cid = stub_buf(cb);
      static const float tri[9] = {-1, -1, 0, 3, -1, 0, -1, 3, 0};
      nxgal_set_render_targets(NULL, 0, 0); base_state(); nxgal_set_program(tp); set_verts(tri, 3); nxgal_set_topology(4);
      nxgal_buf_assign ca = {0, {cid, 0, 16, 1}}; nxgal_set_storage_buffers(&ca, 1);
      nxgal_viewport v1 = {0, 0, 24, 20, {0, 2, 4, 6}, 0, 1}; nxgal_set_viewports(&v1, 1); nxgal_rect s1 = {0, 0, 24, 20}; nxgal_set_scissors(&s1, 1);
      extern uint64_t g_pass_targetless; uint64_t tl0 = g_pass_targetless;
      nxgal_draw(3, 1, 0, 0);
      uint32_t c1[4] = {0}; nxgal_buf_get_data(cid, 0, 16, c1);
      CHECK(c1[0] == 480, "无附件 ①：视口 24×20 期望片元 480，实得 %u", c1[0]);
      nxgal_viewport v2 = {0, 0, 40, 30, {0, 2, 4, 6}, 0, 1}; nxgal_set_viewports(&v2, 1); nxgal_rect s2 = {0, 0, 40, 30}; nxgal_set_scissors(&s2, 1);
      nxgal_draw(3, 1, 0, 0);
      uint32_t c2[4] = {0}; nxgal_buf_get_data(cid, 0, 16, c2);
      CHECK(c2[0] == 480 + 1200, "无附件 ②：再画视口 40×30 期望累计 1680，实得 %u", c2[0]);
      CHECK(g_pass_targetless - tl0 >= 2, "无附件 ②：视口变大应重开通道（无附件开遍 ≥ 2 次），实得 %llu", g_pass_targetless - tl0);
      nxgal_buf_assign none = {0, {0, 0, 0, 0}}; nxgal_set_storage_buffers(&none, 1);
      nxgal_set_render_targets(&g_rt, 1, 0); nxgal_set_program(g_prog); }

    // 回归（丝之歌测试机2 10-20 第 24 帧）：临时内存建块失败时 gal_transient 返回 NULL，原先 clr_draw 往 NULL 写清屏参数 SIGSEGV。
    // 期望：注入失败期间局部清屏 / 绘制都跳过、不崩、目标保持原值（0）；撤掉注入后同样的清屏 / 绘制照常出期望值
    printf("· 临时内存建块失败（注入）：局部清屏 + 绘制跳过不崩、目标保持 0；撤注入后清屏框内 255 0 0 255、四边形 51 102 153 255\n");
    { nxgal_set_render_targets(&g_rt, 1, 0); base_state(); clear_rt(0, 0, 0, 0);
      // 先用一次临时内存再读回：读回会提交，当前块挂上栅栏，下一次取临时内存必走换块路径（注入点）
      uint64_t g0; CHECK(gal_transient(16, 16, &g0) != NULL, "注入前取临时内存失败");
      read_px(px);
      gal_tr_test_fail = 1;
      uint64_t gz = 1; CHECK(gal_transient(16, 16, &gz) == NULL && gz == 0, "注入后 gal_transient 期望 NULL 且 GPU 地址 0，实得地址 %llu", (unsigned long long)gz);
      nxgal_rect sc = {4, 4, 8, 8}; nxgal_set_scissors(&sc, 1);
      float red[4] = {1, 0, 0, 1}; nxgal_clear_color(0, 0, 1, 0xf, red);
      nxgal_rect full = {0, 0, 32, 32}; nxgal_set_scissors(&full, 1);
      set_color(0.2f, 0.4f, 0.6f, 1.0f); set_verts(k_quad, 4); nxgal_set_topology(7); nxgal_draw(4, 1, 0, 0);
      gal_tr_test_fail = 0;
      read_px(px); { uint8_t z[4] = {0, 0, 0, 0}; int n = count_px(px, z); CHECK(n == 1024, "注入期间：期望 1024 像素保持 0，实得 %d", n); }
      nxgal_set_scissors(&sc, 1); nxgal_clear_color(0, 0, 1, 0xf, red); nxgal_set_scissors(&full, 1);
      read_px(px); { uint8_t e[4] = {255, 0, 0, 255}; int n = count_px(px, e); CHECK(n == 64, "撤注入后局部清屏：期望 64 像素 = 255 0 0 255，实得 %d", n); }
      nxgal_draw(4, 1, 0, 0);
      read_px(px); { uint8_t e[4] = {51, 102, 153, 255}; int n = count_px(px, e); CHECK(n == 1024, "撤注入后绘制：期望 1024 像素 = 51 102 153 255，实得 %d", n); } }

    // 曲面细分（第 8 块，gal_tess.m 计算展开）：手写四段 SPIR-V（tests/t_tess_*.spvasm，运行时现翻），两片四边形曲面片各占左 / 右半屏，
    // TCS 给因子外 4 内 4（整数分区）、每片属性 = 片号；TES 输出颜色 (4u(1-u), 片号, 0, 1)，位置 = 四角双线性。
    // 手算期望（不跑被测实现）：D3D11 / Vulkan 整数分区、四边形域、因子全 4 → 每片 (4+1)² = 25 点、2·4² = 32 个三角形（96 个索引），两片 192 个索引；
    //   红色只在 25 个顶点上取 4u(1-u)（u = 0, ¼, ½, ¾, 1 → 0, ¾, 1, ¾, 0），三角形内按 u 线性插值。像素 x（片内 0–15）中心 u = (x + ½) / 16：
    //   x=1：u=0.09375 → ¾·0.375 = 0.28125 → 72；x=4：u=0.28125 → ¾ + ¼·0.125 = 0.78125 → 199；x=7：u=0.46875 → 0.96875 → 247；x=12：u=0.78125 → 0.65625 → 167
    //   （反证：若只细分到 2 段，x=4 是 2·0.28125 = 0.5625 → 143；不细分则全 0）。绿色：左半 0、右半 255（片号 0 / 1）；全屏 1024 像素 α = 255
    printf("· 曲面细分：两片四边形（因子 4）→ 每片 32 三角形；红 = 4u(1-u) 按顶点插值（x=1/4/7/12 → 72/199/247/167）、绿 = 片号\n");
    { NSString *dir = [[NSString stringWithUTF8String:[[NSProcessInfo processInfo].arguments[0] fileSystemRepresentation]] stringByDeletingLastPathComponent];
      NSData *sv[4]; const char *nm[4] = {"vs", "tcs", "tes", "fs"}; int st[4] = {1, 2, 3, 5}, okf = 1;
      for (int i = 0; i < 4; i++) { sv[i] = [NSData dataWithContentsOfFile:[dir stringByAppendingFormat:@"/t_tess/%s.spv", nm[i]]]; okf &= sv[i] != nil; }
      CHECK(okf, "读不到 %s/t_tess/*.spv（make -C graphics/metal 生成）", dir.UTF8String);
      if (okf) {
        nxgal_shader sh[4]; for (int i = 0; i < 4; i++) sh[i] = (nxgal_shader){sv[i].bytes, (uint32_t)sv[i].length, st[i]};
        uint32_t tp = nxgal_prog_create(sh, 4, NULL, 0, 0);
        int stt = nxgal_prog_status(tp, 1); CHECK(stt == 0, "曲面程序建不出（状态 %d）：%s", stt, nxgal_prog_last_error());
        static const float pv[24] = {0, 0, 0, 0.5f, 0, 0, 0.5f, 1, 0, 0, 1, 0,   0.5f, 0, 0, 1, 0, 0, 1, 1, 0, 0.5f, 1, 0};
        // 统计缓冲建不出（注入 gal_newbuf_test_fail；本单测第一次曲面绘制，ts_init 首建）：本次曲面绘制跳过（跳过数 +1、曲面片 +0）、不崩、目标保持 0；
        //   撤注入后下面两遍照常（ts_init 重试）。旧代码反证：memset(nil.contents) 写空指针 SIGSEGV
        if (stt == 0) {
          nxgal_set_render_targets(&g_rt, 1, 0); base_state(); clear_rt(0, 0, 0, 0);
          nxgal_set_program(tp); set_verts(pv, 8); nxgal_set_topology(14);
          float ol[4] = {1, 1, 1, 1}, il[2] = {1, 1}; nxgal_set_patch_params(4, ol, il);
          uint64_t s0[6]; nxgal_tess_stats(s0);
          gal_newbuf_test_fail = 1; nxgal_draw(8, 1, 0, 0); gal_newbuf_test_fail = 0;
          uint64_t s1[6]; nxgal_tess_stats(s1); read_px(px);
          uint8_t z[4] = {0, 0, 0, 0}; int n = count_px(px, z);
          CHECK(s1[3] - s0[3] == 1 && s1[1] == s0[1] && n == 1024, "统计缓冲建不出：期望跳过 +1、曲面片 +0、1024 像素保持 0，实得 %llu / %llu / %d", s1[3] - s0[3], s1[1] - s0[1], n);
        }
        for (int pass = 0; pass < 2 && stt == 0; pass++) {   // 0 非索引；1 16 位索引（索引 = 0..7）
          nxgal_set_render_targets(&g_rt, 1, 0); base_state(); clear_rt(0, 0, 0, 0);
          nxgal_set_program(tp); set_verts(pv, 8); nxgal_set_topology(14 /* Patches */);
          float ol[4] = {1, 1, 1, 1}, il[2] = {1, 1}; nxgal_set_patch_params(4, ol, il);
          uint64_t s0[6]; nxgal_tess_stats(s0);
          void gal_pool_req(uint64_t *, uint64_t *); uint64_t ps0, pg0, ps1, pg1; gal_pool_req(&ps0, &pg0);
          if (pass == 0) nxgal_draw(8, 1, 0, 0);
          else { uint16_t ix[8] = {0, 1, 2, 3, 4, 5, 6, 7}; id<MTLBuffer> ib = [dev newBufferWithBytes:ix length:16 options:MTLResourceStorageModeShared]; gal_res_add(ib);
                 nxgal_buf_range r = {stub_buf(ib), 0, 16, 0}; nxgal_set_index_buffer(&r, 1 /* UShort */); nxgal_draw_indexed(8, 1, 0, 0, 0); }
          gal_pool_req(&ps1, &pg1);
          read_px(px);
          uint64_t s1[6]; nxgal_tess_stats(s1);
          const char *pn = pass ? "索引" : "非索引";
          CHECK(pg1 - pg0 >= 331808 && ps1 - ps0 < 4096, "%s 分界 ③：期望 GPU 池 ≥ 331808、共享池 < 4096，实得 GPU +%llu、共享 +%llu", pn, pg1 - pg0, ps1 - ps0);
          CHECK(s1[0] - s0[0] == 1 && s1[1] - s0[1] == 2 && s1[3] == s0[3], "%s：期望 1 次曲面绘制、2 片、0 跳过，实得 %llu / %llu / %llu", pn, s1[0] - s0[0], s1[1] - s0[1], s1[3] - s0[3]);
          CHECK(s1[5] - s0[5] == 192 && s1[4] == s0[4], "%s：期望展开 192 个索引（2 片 × 32 三角形）、0 丢弃，实得 %llu / %llu", pn, s1[5] - s0[5], s1[4] - s0[4]);
          int na = 0, gl = 0, gr = 0; for (int y = 0; y < 32; y++) for (int x = 0; x < 32; x++) { const uint8_t *q = px + (y * 32 + x) * 4; na += q[3] == 255; if (x < 16) gl += q[1] == 0; else gr += q[1] == 255; }
          CHECK(na == 1024 && gl == 512 && gr == 512, "%s：期望 α 全 1024、左半绿 0 共 512、右半绿 255 共 512，实得 %d / %d / %d", pn, na, gl, gr);
          static const int xs[4] = {1, 4, 7, 12}, ex[4] = {72, 199, 247, 167};
          for (int k = 0; k < 4; k++) for (int h = 0; h < 2; h++) { int x = xs[k] + 16 * h, bad = 0; for (int y = 0; y < 32; y++) { int r = px[(y * 32 + x) * 4]; bad += r < ex[k] - 1 || r > ex[k] + 1; }
            CHECK(!bad, "%s：第 %d 列红期望 %d±1（32 行），%d 行不符（(%d,0) = %u）", pn, x, ex[k], bad, x, px[x * 4]); }
        }
        nxgal_set_topology(4);
      } }


    // 原始位顶点输入（Ryujinx 补丁 vattr-raw，10-21 画面·着色器线）：手写 SPIR-V（tests/t_vraw_*.spvasm，形态照补丁：顶点输入 uvec4、名字 s2a_raw<位置>），运行时现翻。
    //   顶点着色器把输入 1 的寄存器位原样透传，片元写进 RGBA32Uint 目标，读回 (0,0) 比 Maxwell 顶点取数单元的寄存器位（按格式规格手算，选的值浮点表示都精确，逐位比）：
    //   R8G8B8A8Unorm (0,255,0,255) → 0, 1.0f, 0, 1.0f；R8G8Snorm (127,−127) → 1.0f, −1.0f, 0, 1.0f（缺分量）；R8G8B8A8Uscaled (1,2,3,200) → 1.0f, 2.0f, 3.0f, 200.0f；
    //   R16G16Sint (−2, 5) → 0xfffffffe, 5, 0, 1（整数缺分量补 1）；R16G16B16A16Float (1, −2, 0.5, 0) → 同值浮点位；R10G10B10A2Unorm (1023, 0, 0, 3) → 1.0f, 0, 0, 1.0f
    //   原始位着色器不看 NXGAL_VPULL、一律自取（本单测缺省不设、Makefile 另跑一遍设 1，两遍都要过）。
    //   反证：旧口径同一客体着色器要按属性类型出 float4 / int4 两种声明；按 float4 读 R16G16Sint 得 -2.0f 的位 0xc0000000 而不是 0xfffffffe（t_vpull 里逐格核过）
    printf("· 原始位顶点输入：uvec4 s2a_raw<位置> → 一律自取（NXGAL_VPULL=%s）、寄存器位按 Maxwell 语义，7 种格式逐位比\n", getenv("NXGAL_VPULL") ? getenv("NXGAL_VPULL") : "未设");
    { NSString *dir = [[NSString stringWithUTF8String:[[NSProcessInfo processInfo].arguments[0] fileSystemRepresentation]] stringByDeletingLastPathComponent];
      NSData *vsd = [NSData dataWithContentsOfFile:[dir stringByAppendingString:@"/t_vraw/vs.spv"]], *fsd = [NSData dataWithContentsOfFile:[dir stringByAppendingString:@"/t_vraw/fs.spv"]];
      CHECK(vsd && fsd, "读不到 %s/t_vraw/*.spv（make -C graphics/metal 生成）", dir.UTF8String);
      if (vsd && fsd) {
        nxgal_shader sh[2] = {{vsd.bytes, (uint32_t)vsd.length, 1}, {fsd.bytes, (uint32_t)fsd.length, 5}};
        uint32_t rp = nxgal_prog_create(sh, 2, NULL, 0, 0xf);
        int stt = nxgal_prog_status(rp, 1); CHECK(stt == 0, "原始位程序建不出（状态 %d）：%s", stt, nxgal_prog_last_error());
        gal_prog *gp = gal_prog_get(rp);
        CHECK(stt == 0 && gp && gp->vs_pulled && gp->vs_inputs == 0x3, "原始位程序应走自取、输入位置 0 / 1（实得 自取 %d 输入 %#x）", gp ? gp->vs_pulled : -1, gp ? gp->vs_inputs : 0);
        typedef struct { const char *n; int fmt; uint8_t b[8]; uint32_t e[4]; } vr_t;
        const uint32_t F1 = 0x3f800000u, FM1 = 0xbf800000u;
        vr_t vc[] = {
            {"R8G8B8A8Unorm", F_R8G8B8A8Unorm, {0, 255, 0, 255}, {0, F1, 0, F1}},
            {"R8G8Snorm", F_R8G8Snorm, {0x7f, 0x81}, {F1, FM1, 0, F1}},
            {"R8G8B8A8Uscaled", F_R8G8B8A8Uscaled, {1, 2, 3, 200}, {0x3f800000u, 0x40000000u, 0x40400000u, 0x43480000u}},
            {"R16G16Sint", F_R16G16Sint, {0xfe, 0xff, 5, 0}, {0xfffffffeu, 5, 0, 1}},
            {"R16G16B16A16Float", F_R16G16B16A16Float, {0x00, 0x3c, 0x00, 0xc0, 0x00, 0x38, 0, 0}, {F1, 0xc0000000u, 0x3f000000u, 0}},
            {"R10G10B10A2Unorm", F_R10G10B10A2Unorm, {0xff, 0x03, 0x00, 0xc0}, {F1, 0, 0, F1}},
            // GAL 格式 0（10-21 塞尔达）：描述按位编码是 0，旧代码当「不支持」按零属性读 → 0, 0, 0, 0；应是 255 → 1.0f、缺分量 0, 0, 1.0f
            {"R8Unorm（GAL 格式 0）", F_R8Unorm, {255}, {F1, 0, 0, F1}},
        };
        nxgal_tex_info ui = ti(4, 4, F_R32G32B32A32Uint, 16); uint32_t urt = nxgal_tex_create(&ui);
        static const float tri[9] = {-1, -1, 0, 3, -1, 0, -1, 3, 0};
        id<MTLBuffer> pb = [dev newBufferWithBytes:tri length:sizeof tri options:MTLResourceStorageModeShared]; gal_res_add(pb);
        uint32_t pbid = stub_buf(pb);
        for (int k = 0; k < (int)(sizeof vc / sizeof *vc) && stt == 0; k++) {
          id<MTLBuffer> ab = [dev newBufferWithBytes:vc[k].b length:16 options:MTLResourceStorageModeShared]; gal_res_add(ab);
          nxgal_set_render_targets(&urt, 1, 0); base_state();
          nxgal_viewport vp4 = {0, 0, 4, 4, {0, 2, 4, 6}, 0, 1}; nxgal_set_viewports(&vp4, 1);
          nxgal_rect sc4 = {0, 0, 4, 4}; nxgal_set_scissors(&sc4, 1);
          nxgal_set_program(rp);
          nxgal_vbuf vb[2] = {{{pbid, 0, (int32_t)sizeof tri, 0}, 12, 0}, {{stub_buf(ab), 0, 16, 0}, 0, 0}}; nxgal_set_vertex_buffers(vb, 2);
          nxgal_vattr at[2] = {{0, 0, 0, F_R32G32B32Float}, {1, 0, 0, vc[k].fmt}}; nxgal_set_vertex_attribs(at, 2);
          nxgal_set_topology(4);
          nxgal_draw(3, 1, 0, 0);
          uint32_t ub[4 * 4 * 4]; memset(ub, 0xee, sizeof ub);
          int rd = nxgal_tex_get_data(urt, 0, 0, ub, sizeof ub) == (int)sizeof ub;
          CHECK(rd && !memcmp(ub, vc[k].e, 16), "%s：期望寄存器位 %08x %08x %08x %08x 实得 %08x %08x %08x %08x", vc[k].n, vc[k].e[0], vc[k].e[1], vc[k].e[2], vc[k].e[3], ub[0], ub[1], ub[2], ub[3]);
        }
        nxgal_set_program(g_prog); nxgal_prog_release(rp);
      } }

    // 两池分界（gal_pool_req 累计请求字节）。期望手算：
    //   ① 非索引四边形 4 顶点：模式索引 CPU 生成 6 个 32 位 → 共享池 +24 字节及以上（另有 CPU 写的参数集），GPU 池 +0
    //   ② 索引扇形 4 个索引、索引缓冲刚被 GPU 拷贝写过（CPU 侧读不到当前内容）→ GPU 转换：输出 2 三角 6 个 32 位 → GPU 池 +24 及以上
    //   ③ 曲面绘制（下方曲面段第 0 遍，2 片、因子 4）：域点上限 min(2·4225, 2^20) = 8450 × 16 = 135200、索引上限 min(2·24576, 2^22) = 49152 × 4 = 196608
    //      → GPU 池 ≥ 331808 字节；共享池只有 CPU 写的参数（顶点号 / 片数 / 展开参数 / 控制点数 + 参数集）< 4096 字节
    //   反证（改前）：曲面与 GPU 转换全走共享池 → ③ 共享池 ≥ 331808、GPU 池 0
    { void gal_pool_req(uint64_t *, uint64_t *); uint64_t s0, g0, s1, g1;
      nxgal_set_render_targets(&g_rt, 1, 0); base_state(); clear_rt(0, 0, 0, 0); set_color(0.2f, 0.4f, 0.6f, 1.0f); set_verts(k_quad, 4); nxgal_set_topology(7);
      gal_pool_req(&s0, &g0); nxgal_draw(4, 1, 0, 0); gal_pool_req(&s1, &g1);
      CHECK(s1 - s0 >= 24 && g1 == g0, "分界 ①：期望共享 ≥ 24、GPU +0，实得共享 +%llu、GPU +%llu", s1 - s0, g1 - g0);
      uint16_t fan[4] = {0, 1, 2, 3}; uint32_t src = nxgal_buf_create(8, 0), ib = nxgal_buf_create(8, 0);
      nxgal_buf_set_data(src, 0, fan, 8); nxgal_buf_copy(src, ib, 0, 0, 8);
      nxgal_buf_range ir = {ib, 0, 8, 0}; nxgal_set_index_buffer(&ir, 1); nxgal_set_topology(6);
      gal_pool_req(&s0, &g0); nxgal_draw_indexed(4, 1, 0, 0, 0); gal_pool_req(&s1, &g1);
      CHECK(g1 - g0 >= 24, "分界 ②：期望 GPU 池 ≥ 24（GPU 转换输出），实得 GPU +%llu、共享 +%llu", g1 - g0, s1 - s0);
      read_px(px); { uint8_t e[4] = {51, 102, 153, 255}; int n = count_px(px, e); CHECK(n == 1024, "分界 ②：扇形整屏期望 1024 像素 = 51 102 153 255，实得 %d", n); }
      nxgal_set_topology(4); }

    // GPU 临时池（gal_transient_gpu，私有存储）。期望手算：
    //   ① 地址：同一次提交里取 8 块 16 MB（都在途、不能复用 → 新建 8 块），进程 IOAccelerator（标签 100）映射增长 ≤ 4 MB（私有存储不映射进进程，期望 0）；
    //      同样 8 块 16 MB 走共享临时池（gal_transient）→ 增长 ≥ 128 MB（反证：改前曲面 / 索引转换的大块就是这样吃低区的）
    //   ② 回收：每次提交取 1 块 16 MB 再等完、连做 5 次 → 块数不增（已有空闲 16 MB 块复用）
    //   ③ 选最合身的块：先在一次提交里占满全部 16 MB 空闲块 + 1 MB（新建一块 4 MB），等完；再在一次提交里先取 1 MB、后取同样多块 16 MB →
    //      1 MB 落进 4 MB 块，16 MB 各落一块旧块，块数不增（首个合适即取时 1 MB 会占掉一块 16 MB，最后一块 16 MB 只能新建，块数 +1）
    //   ④ 建块失败（注入 gal_tg_test_fail）→ 返回 0、不崩；撤注入后照常
    //   ⑤ 同一提交内两次取址不重叠、按 256 对齐
    printf("· GPU 临时池：私有块不占进程地址（标签 100 增长）、按栅栏回收、选最合身的块、建块失败返回 0\n");
    { void gal_tg_stats(int *n, uint64_t *bytes); extern int gal_tg_test_fail;
      uint64_t (^tag100)(void) = ^uint64_t(void) { vm_address_t a = 0; uint64_t t = 0; for (;;) { vm_size_t sz = 0; natural_t d = 0; vm_region_submap_info_data_64_t i; mach_msg_type_number_t c = VM_REGION_SUBMAP_INFO_COUNT_64;
          if (vm_region_recurse_64(mach_task_self(), &a, &sz, &d, (vm_region_recurse_info_t)&i, &c) != KERN_SUCCESS) break; if (i.user_tag == 100) t += sz; a += sz; } return t; };
      const uint32_t M16 = 16u << 20; int n0, n1; uint64_t b0, b1;
      gal_finish(); gal_tg_stats(&n0, &b0);
      uint64_t v0 = tag100(); uint64_t adr[8]; int ok = 1;
      (void)gal_blit_enc(); for (int k = 0; k < 8; k++) { adr[k] = gal_transient_gpu(M16, 16); ok &= adr[k] != 0; }
      uint64_t v1 = tag100(); gal_tg_stats(&n1, &b1);
      CHECK(ok && n1 - n0 >= 8, "① 取 8 块 16 MB：期望全成功、块数 +8 及以上（同一提交都在途），实得成功 %d、块数 +%d", ok, n1 - n0);
      CHECK(v1 - v0 <= (4u << 20), "① 私有 8×16 MB：期望标签 100 增长 ≤ 4 MB，实得 %llu MB", (unsigned long long)((v1 - v0) >> 20));
      gal_finish();
      uint64_t s0 = tag100(); (void)gal_blit_enc(); int sok = 1; for (int k = 0; k < 8; k++) { uint64_t g; sok &= gal_transient(M16, 16, &g) != NULL; } uint64_t s1 = tag100(); gal_finish();
      CHECK(sok && s1 - s0 >= (128u << 20), "① 反证 共享 8×16 MB：期望标签 100 增长 ≥ 128 MB，实得 %llu MB（成功 %d）", (unsigned long long)((s1 - s0) >> 20), sok);
      gal_tg_stats(&n0, &b0);
      for (int r = 0; r < 5; r++) { (void)gal_blit_enc(); CHECK(gal_transient_gpu(M16, 16) != 0, "② 第 %d 次取 16 MB 失败", r); gal_finish(); }
      gal_tg_stats(&n1, &b1); CHECK(n1 == n0, "② 回收：期望块数不变 %d，实得 %d", n0, n1);
      // ③ 清空池后：提交 1 取 16 MB（块 0，16 MB）+ 1 MB（块 0 已满 → 新建块 1，4 MB），等完 → 空闲：块 0 16 MB、块 1 4 MB。
      //    提交 2 先取 1 MB：最合身 = 块 1；再取 16 MB：块 0 空闲照用 → 块数仍 2（首个合适即取：1 MB 占块 0，16 MB 只能新建 → 3）
      void gal_tg_test_reset(void); gal_finish(); gal_tg_test_reset();
      (void)gal_blit_enc(); gal_transient_gpu(M16, 16); gal_transient_gpu(1u << 20, 16); gal_finish(); gal_tg_stats(&n0, &b0);
      (void)gal_blit_enc(); gal_transient_gpu(1u << 20, 16); gal_transient_gpu(M16, 16); gal_finish(); gal_tg_stats(&n1, &b1);
      CHECK(n0 == 2 && b0 == (20u << 20) && n1 == 2 && b1 == (20u << 20), "③ 选最合身：期望前后都 2 块 20 MB，实得 %d 块 %llu MB → %d 块 %llu MB", n0, (unsigned long long)(b0 >> 20), n1, (unsigned long long)(b1 >> 20));
      gal_finish(); (void)gal_blit_enc(); gal_transient_gpu(M16, 16); gal_transient_gpu(M16, 16);   // 当前块用满 → 下一次必走换块路径（注入点）
      gal_tg_test_fail = 1; uint64_t gz = gal_transient_gpu(M16, 16); gal_tg_test_fail = 0;
      CHECK(gz == 0, "④ 注入后期望返回 0，实得 %#llx", (unsigned long long)gz);
      uint64_t a1 = gal_transient_gpu(100, 256), a2 = gal_transient_gpu(100, 256);
      CHECK(a1 && a2 && !(a1 & 255) && !(a2 & 255) && (a2 >= a1 + 100 || a1 >= a2 + 100), "⑤ 撤注入后两次取址：期望非 0、256 对齐、不重叠，实得 %#llx %#llx", (unsigned long long)a1, (unsigned long long)a2);
      gal_finish(); }
    // ⑥⑦⑧ 按帧回收（10-23 巫师3 真机池只建不还 0→340 MB）：每 30 帧一段记同时占用峰值，上限 = 近 8 段最大峰值 + 4 MB，提交后放超出的空闲块
    //   ⑥ 一次提交占 8 块 16 MB（峰值 128 MB），之后 9 段每段一次提交只取 1 MB → 池缩到 1 块 16 MB（上限 16 + 4 MB），回收 7 块
    //   ⑦ 同样高峰后只过 3 段 → 高峰仍在窗口内，一块不放（8 块）
    //   ⑧ 每段都占 8 块 16 MB、连 10 段 → 不回收（平稳负载不来回建删）
    printf("· GPU 临时池按帧回收：高峰过后约 8 秒缩回、窗口内不放、平稳负载不建删\n");
    { void gal_tg_stats(int *n, uint64_t *bytes); void gal_tg_test_reset(void); uint64_t gal_tg_freed(void); extern uint64_t gal_tg_test_frames;
      const uint32_t M16 = 16u << 20; int n; uint64_t b, f0;
      void (^spike)(void) = ^{ (void)gal_blit_enc(); for (int k = 0; k < 8; k++) gal_transient_gpu(M16, 16); gal_finish(); };
      gal_finish(); gal_tg_test_reset(); f0 = gal_tg_freed(); spike();
      for (int e = 0; e < 9; e++) { gal_tg_test_frames += 30; (void)gal_blit_enc(); gal_transient_gpu(1u << 20, 16); gal_finish(); }
      gal_tg_stats(&n, &b);
      CHECK(n == 1 && b == M16 && gal_tg_freed() - f0 == 7, "⑥ 高峰过后 9 段：期望 1 块 16 MB、回收 7 块，实得 %d 块 %llu MB、回收 %llu 块", n, (unsigned long long)(b >> 20), (unsigned long long)(gal_tg_freed() - f0));
      gal_finish(); gal_tg_test_reset(); f0 = gal_tg_freed(); spike();
      for (int e = 0; e < 3; e++) { gal_tg_test_frames += 30; (void)gal_blit_enc(); gal_transient_gpu(1u << 20, 16); gal_finish(); }
      gal_tg_stats(&n, &b);
      CHECK(n == 8 && gal_tg_freed() == f0, "⑦ 高峰后 3 段（仍在窗口内）：期望 8 块、回收 0，实得 %d 块、回收 %llu", n, (unsigned long long)(gal_tg_freed() - f0));
      gal_finish(); gal_tg_test_reset(); f0 = gal_tg_freed();
      for (int e = 0; e < 10; e++) { gal_tg_test_frames += 30; spike(); }
      gal_tg_stats(&n, &b);
      CHECK(n == 8 && gal_tg_freed() == f0, "⑧ 每段都占 8 块 16 MB、连 10 段：期望 8 块、回收 0，实得 %d 块、回收 %llu", n, (unsigned long long)(gal_tg_freed() - f0));
      gal_finish(); gal_tg_test_reset(); gal_tg_test_frames = 0; }

    // GPU 空闲即提交（gal_core.m idle_commit_min，缺省关）：GPU 做完了全部已提交的活（gal_finish 后）时，录一遍 3 次绘制、换渲染目标收掉这一遍——
    //   开（最少 2 条）：这次入口返回时提交 → 在录命令缓冲的身份（gal_cb_id）前进 1；关：不提交、身份不变；开但只录 1 条（不够最少数）：不提交
    { extern int gal_idle_commit_test; uint64_t id0;
      printf("· GPU 空闲即提交：GPU 闲时收遍提交、开关关或绘制不够最少数不提交\n");
      for (int mode = 0; mode < 3; mode++) {
        gal_finish(); nxgal_set_render_targets(&g_rt, 1, 0); base_state(); set_verts(k_quad, 4); set_color(0, 1, 0, 1);
        gal_idle_commit_test = mode == 0 ? 0 : 2; int draws = mode == 2 ? 1 : 3;
        nxgal_draw(4, 1, 0, 0); id0 = gal_cb_id();
        for (int k = 1; k < draws; k++) nxgal_draw(4, 1, 0, 0);
        nxgal_set_render_targets(&g_white, 1, 0);   // 换目标：收掉上一遍（gal_enc_end），入口返回时按标志提交
        uint64_t id1 = gal_cb_id();
        if (mode == 1) CHECK(id1 == id0 + 1, "开、GPU 闲、3 条绘制：期望提交 1 次（身份 %llu → %llu），实得 → %llu", (unsigned long long)id0, (unsigned long long)(id0 + 1), (unsigned long long)id1);
        else CHECK(id1 == id0, "%s：期望不提交（身份不变 %llu），实得 %llu", mode == 0 ? "关" : "开但只 1 条绘制（不够最少 2 条）", (unsigned long long)id0, (unsigned long long)id1);
      }
      gal_idle_commit_test = -1; gal_finish(); }

    nxgal_shutdown();
    printf("%s：%d / %d 项通过\n", g_fail ? "失败" : "通过", g_checks - g_fail, g_checks);
    return g_fail ? 1 : 0;
}
GAL_MTL4_ZONE_END
