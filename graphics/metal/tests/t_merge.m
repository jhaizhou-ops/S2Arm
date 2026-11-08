// 两遍合一（gal_pass.m，NXGAL_PASS_MERGE=1）单测：走 nxgal_* 全路径画到离屏目标，读回比手算期望；渲染编码器数（g_gp_n[GP_RENC]）与合遍次数（g_pass_merged）核「确实没断遍」。
// 期望值都按 GAL / Vulkan 语义手算（深度 Less、清屏值、采样同一张贴图），不跑被测实现。
// 用法：t_merge（缺省自己置 NXGAL_PASS_MERGE=1，同渲染器缺省）；t_merge --off（不开合遍：画面期望不变、编码器数 / 合遍次数按「每换组一遍」核，用来反证计数判据）
#import <Metal/Metal.h>
#include "fixture.h"   // 固定 MSL 走离线 metallib 夹具（不是被测对象，不经运行时编译服务）
#include "../gal_abi.h"
#include "../gal_internal.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

GAL_MTL4_ZONE_BEGIN
extern uint64_t g_pass_merged;
static int g_fail, g_checks;
#define CHECK(cond, ...) do { g_checks++; if (!(cond)) { g_fail++; printf("  ✗ " __VA_ARGS__); printf("\n"); } } while (0)

// vs：位置直取属性；fs：常量色 × 贴图中心采样（贴图整张同色时 = 同一像素读）；fs2：两个颜色输出都写常量色
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
"struct O2 { float4 c0 [[color(0)]]; float4 c1 [[color(1)]]; };\n"
"fragment O2 fs2(VOut in [[stage_in]], constant Set0 &s0 [[buffer(0)]]) { O2 o; o.c0 = s0.ubo[0]; o.c1 = s0.ubo[0]; return o; }\n";

static MTL4LibraryFunctionDescriptor *fn(id<MTLLibrary> l, NSString *n) { MTL4LibraryFunctionDescriptor *f = [MTL4LibraryFunctionDescriptor new]; f.library = l; f.name = n; return f; }
static gal_arg g_args[3] = {
    {GAL_ARG_UBO, 0, 0, 0, 1, 1u << 5},
    {GAL_ARG_TEX, 2, 0, 0, 1, 1u << 5},
    {GAL_ARG_SMP, 2, 0, 8, 1, 1u << 5},
};
enum { RGBA8 = 36, D32F = 51 };
static nxgal_tex_info ti(int w, int h, int fmt, int bpp) { nxgal_tex_info i = {w, h, 1, 1, 1, 1, 1, bpp, fmt, 0, 1, {2, 3, 4, 5}}; return i; }
static uint32_t g_white, g_smp;

static void set_color(float r, float g, float b, float a) {
    float c[4] = {r, g, b, a}; uint32_t u = nxgal_buf_create(16, 0); nxgal_buf_set_data(u, 0, c, 16);
    nxgal_buf_assign a0 = {0, {u, 0, 16, 0}}; nxgal_set_uniform_buffers(&a0, 1);
}
static void set_quad(float z) {
    float v[12] = {-1, -1, z, 1, -1, z, 1, 1, z, -1, 1, z};
    uint32_t b = nxgal_buf_create(48, 0); nxgal_buf_set_data(b, 0, v, 48);
    nxgal_vbuf vb = {{b, 0, 48, 0}, 12, 0}; nxgal_set_vertex_buffers(&vb, 1);
    nxgal_vattr at = {0, 0, 0, 33}; nxgal_set_vertex_attribs(&at, 1); nxgal_set_topology(7 /* Quads */);
}
static void base_state(uint32_t prog) {
    nxgal_blend b = {0, {0, 0, 0, 0}, 1, 2, 1, 1, 2, 1}; for (int i = 0; i < 8; i++) nxgal_set_blend(i, &b);
    nxgal_depth_test d = {0, 0, 8}; nxgal_set_depth_test(&d);
    nxgal_stencil s; memset(&s, 0, sizeof s); nxgal_set_stencil_test(&s);
    nxgal_set_face_culling(0, 0x405); nxgal_set_front_face(0x901);
    nxgal_viewport vp = {0, 0, 32, 32, {0, 2, 4, 6}, 0, 1}; nxgal_set_viewports(&vp, 1);
    nxgal_rect sc = {0, 0, 32, 32}; nxgal_set_scissors(&sc, 1);
    uint32_t m[8] = {0xf, 0xf, 0xf, 0xf, 0xf, 0xf, 0xf, 0xf}; nxgal_set_color_masks(m, 8);
    nxgal_set_texture_sampler(5, 0, g_white, g_smp);
    nxgal_set_program(prog);
}
static int count_px(uint32_t tex, const uint8_t e[4]) {
    uint8_t px[32 * 32 * 4]; if (nxgal_tex_get_data(tex, 0, 0, px, sizeof px) != sizeof px) return -1;
    int n = 0; for (int i = 0; i < 32 * 32; i++) n += !memcmp(px + i * 4, e, 4); return n;
}
static void clear_full(int idx, float r, float g, float b, float a) { float c[4] = {r, g, b, a}; nxgal_rect full = {0, 0, 0xffff, 0xffff}; nxgal_set_scissors(&full, 1); nxgal_clear_color(idx, 0, 1, 0xf, c); nxgal_rect sc = {0, 0, 32, 32}; nxgal_set_scissors(&sc, 1); }
static void clear_depth(float v) { nxgal_rect full = {0, 0, 0xffff, 0xffff}; nxgal_set_scissors(&full, 1); nxgal_clear_ds(0, 1, v, 1, 0, 0); nxgal_rect sc = {0, 0, 32, 32}; nxgal_set_scissors(&sc, 1); }

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    int off = argc > 1 && !strcmp(argv[1], "--off");
    setenv("NXGAL_PASS_MERGE", off ? "0" : "1", 1);
    if (nxgal_init(0)) return 2;
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    NSError *err = nil;
    id<MTLLibrary> lib = fx_lib(dev, @"t_merge", k_msl, &err);
    if (!lib) { printf("MSL 编译失败：%s\n", err.localizedDescription.UTF8String); return 2; }
    static gal_prog P, P2;
    P.live = 1; P.fn[1] = fn(lib, @"vs"); P.fn[5] = fn(lib, @"fs"); P.set_size[0] = 8; P.set_stages[0] = 1u << 5; P.set_size[2] = 16; P.set_stages[2] = 1u << 5;
    P.args = g_args; P.nargs = 3; P.stage_set_size[5][0] = 8; P.stage_set_size[5][2] = 16; P.vs_inputs = 1; P.fs_outputs = 1; P.hash = 0x4111;
    for (int i = 0; i < 6; i++) P.size_buf_index[i] = -1;
    P2 = P; P2.fn[5] = fn(lib, @"fs2"); P2.nargs = 1; P2.set_size[2] = 0; P2.set_stages[2] = 0; P2.stage_set_size[5][2] = 0; P2.fs_outputs = 3; P2.hash = 0x4222;
    uint32_t prog = gal_prog_register_builtin(&P), prog2 = gal_prog_register_builtin(&P2);
    nxgal_sampler_info si = {1, 1, 1, 2, 2, 2, 0, 8, {0, 0, 0, 0}, 0, 1000, 0, 1}; g_smp = nxgal_sampler_create(&si);
    nxgal_tex_info wi = ti(1, 1, RGBA8, 4); g_white = nxgal_tex_create(&wi); uint8_t w4[4] = {255, 255, 255, 255}; nxgal_tex_set_data(g_white, 0, 0, NULL, w4, 4);
    nxgal_tex_info ci = ti(32, 32, RGBA8, 4), di = ti(32, 32, D32F, 4);
    const uint8_t green[4] = {0, 255, 0, 255}, blue[4] = {0, 0, 255, 255}, red[4] = {255, 0, 0, 255}, gray[4] = {64, 64, 64, 64};

    // 用例 1：颜色 + 深度 → 只剩深度（暗黑3 每帧 2 次的那类）→ 换颜色。
    // ① [A] + D：A 清 0、D 清 1.0，画 z=0.5 绿（Less、写深度）→ A 全绿、D = 0.5
    // ② [空] + D：画 z=0.25（只写深度）→ D = 0.25；合遍时 A 是隐藏附件（写掩码 0），必须保持全绿
    // ③ [A2] + D：A2 清蓝，画 z=0.35 红（Less）：0.35 < 0.25 不成立 → 不画，A2 全蓝（②的深度丢了 D 仍是 0.5 就会画成红）
    // 编码器：开 → 合遍 → 换颜色开新遍：开合遍 2 个、合遍 1 次；不开 3 个、0 次
    printf("· 颜色 + 深度 → 只剩深度 → 换颜色：A 全绿、A2 全蓝、D 全 0.25；开合遍 2 个渲染编码器 / 合遍 1 次\n");
    {
        uint32_t A = nxgal_tex_create(&ci), A2 = nxgal_tex_create(&ci), D = nxgal_tex_create(&di);
        nxgal_set_render_targets(&A, 1, D); base_state(prog);
        clear_full(0, 0, 0, 0, 0); clear_depth(1.0f);
        uint64_t e0 = g_gp_n[GP_RENC], m0 = g_pass_merged;
        nxgal_depth_test dt = {1, 1, 2 /* Less */}; nxgal_set_depth_test(&dt);
        set_quad(0.5f); set_color(0, 1, 0, 1); nxgal_draw(4, 1, 0, 0);
        uint32_t none = 0; nxgal_set_render_targets(&none, 1, D);
        set_quad(0.25f); set_color(1, 0, 1, 1); nxgal_draw(4, 1, 0, 0);
        nxgal_set_render_targets(&A2, 1, D); clear_full(0, 0, 0, 1, 1);
        set_quad(0.35f); set_color(1, 0, 0, 1); nxgal_draw(4, 1, 0, 0);
        uint64_t enc = g_gp_n[GP_RENC] - e0, mg = g_pass_merged - m0;
        int na = count_px(A, green), na2 = count_px(A2, blue);
        float dp[1024]; nxgal_tex_get_data(D, 0, 0, dp, sizeof dp); int nd = 0; for (int i = 0; i < 1024; i++) nd += dp[i] == 0.25f;
        CHECK(na == 1024, "A 期望 1024 像素绿（隐藏附件不被只写深度的绘制改），实得 %d", na);
        CHECK(na2 == 1024, "A2 期望 1024 像素蓝（②写的深度 0.25 挡住 z=0.35），实得 %d", na2);
        CHECK(nd == 1024, "D 期望 1024 个 0.25，实得 %d（[0] = %g）", nd, dp[0]);
        CHECK(enc == (off ? 3u : 2u), "渲染编码器期望 %d 个，实得 %llu", off ? 3 : 2, (unsigned long long)enc);
        CHECK(mg == (off ? 0u : 1u), "合遍次数期望 %d，实得 %llu", off ? 0 : 1, (unsigned long long)mg);
        nxgal_depth_test doff = {0, 0, 8}; nxgal_set_depth_test(&doff);
        nxgal_tex_release(A); nxgal_tex_release(A2); nxgal_tex_release(D);
    }

    // 用例 2：隐藏附件被采样必须先收遍（隐藏附件还在片上、没存回）。
    // B 先写成灰（64×4，进内存），① [A, B] + D：A、B 清 0（挂起清屏，开遍以清读入、内存里 B 仍是灰），fs2 两个输出都写红 → 片上 A = B = 红
    // ② [A, 空] + D（B 隐藏）：画 A = 白 × B 中心采样。收遍了 B 已存回 → 读到红 → A 全红；没收遍 → 读到内存里的旧灰 → A 全灰
    // 编码器：开 → 合遍 → 采样隐藏附件收遍、按逻辑组重开：开合遍 2 个 / 合遍 1 次；不开也是 2 个（换组即收）/ 0 次
    printf("· 隐藏附件被采样先收遍：A 全红（读到 B 的新内容，不是内存里的旧灰）；开合遍 2 个渲染编码器 / 合遍 1 次\n");
    {
        uint32_t A = nxgal_tex_create(&ci), B = nxgal_tex_create(&ci), D = nxgal_tex_create(&di);
        uint8_t g[32 * 32 * 4]; memset(g, 64, sizeof g); nxgal_tex_set_data(B, 0, 0, NULL, g, sizeof g);
        uint32_t ab[2] = {A, B}; nxgal_set_render_targets(ab, 2, D); base_state(prog2);
        clear_full(0, 0, 0, 0, 0); clear_full(1, 0, 0, 0, 0); clear_depth(1.0f);
        uint64_t e0 = g_gp_n[GP_RENC], m0 = g_pass_merged;
        set_quad(0.5f); set_color(1, 0, 0, 1); nxgal_draw(4, 1, 0, 0);
        uint32_t a0[2] = {A, 0}; nxgal_set_render_targets(a0, 2, D);
        nxgal_set_program(prog); nxgal_set_texture_sampler(5, 0, B, g_smp); set_color(1, 1, 1, 1); nxgal_draw(4, 1, 0, 0);
        uint64_t enc = g_gp_n[GP_RENC] - e0, mg = g_pass_merged - m0;
        int na = count_px(A, red), ng = count_px(A, gray), nb = count_px(B, red);
        CHECK(na == 1024, "A 期望 1024 像素红，实得 %d（其中旧灰 %d：隐藏附件没收遍就被采样）", na, ng);
        CHECK(nb == 1024, "B 期望 1024 像素红，实得 %d", nb);
        CHECK(enc == 2u, "渲染编码器期望 2 个，实得 %llu", (unsigned long long)enc);
        CHECK(mg == (off ? 0u : 1u), "合遍次数期望 %d，实得 %llu", off ? 0 : 1, (unsigned long long)mg);
        nxgal_tex_release(A); nxgal_tex_release(B); nxgal_tex_release(D);
    }

    // 用例 3：不合的情形照旧收遍——深度换了一张（[A] + D1 → [A] + D2）：编码器 2 个、合遍 0 次，A 先绿后被 D2 上 z=0.5 的红盖满
    printf("· 深度附件换一张不合遍：渲染编码器 2 个、合遍 0 次，A 全红\n");
    {
        uint32_t A = nxgal_tex_create(&ci), D1 = nxgal_tex_create(&di), D2 = nxgal_tex_create(&di);
        nxgal_set_render_targets(&A, 1, D1); base_state(prog); clear_full(0, 0, 0, 0, 0); clear_depth(1.0f);
        uint64_t e0 = g_gp_n[GP_RENC], m0 = g_pass_merged;
        nxgal_depth_test dt = {1, 1, 2 /* Less */}; nxgal_set_depth_test(&dt);
        set_quad(0.5f); set_color(0, 1, 0, 1); nxgal_draw(4, 1, 0, 0);
        nxgal_set_render_targets(&A, 1, D2); clear_depth(1.0f);
        set_quad(0.5f); set_color(1, 0, 0, 1); nxgal_draw(4, 1, 0, 0);
        uint64_t enc = g_gp_n[GP_RENC] - e0, mg = g_pass_merged - m0;
        int na = count_px(A, red);
        CHECK(na == 1024, "A 期望 1024 像素红，实得 %d", na);
        CHECK(enc == 2u && mg == 0u, "期望渲染编码器 2 个 / 合遍 0 次，实得 %llu / %llu", (unsigned long long)enc, (unsigned long long)mg);
        nxgal_depth_test doff = {0, 0, 8}; nxgal_set_depth_test(&doff);
        nxgal_tex_release(A); nxgal_tex_release(D1); nxgal_tex_release(D2);
    }

    // 用例 4：无深度的遍也合（塞尔达每帧上百次换组过半是无深度的后处理遍）。
    // ① [A, B] 无深度：A、B 清 0，fs2 两个输出写红 → A = B = 红 ② [A, 空] 无深度（B 隐藏）：画 A = 绿 × 白 → A 全绿，B 隐藏附件保持红
    // 编码器：开合遍 1 个 / 合遍 1 次；不开 2 个 / 0 次
    printf("· 无深度遍 [A, B] → [A, 空]：A 全绿、B 全红；开合遍 1 个渲染编码器 / 合遍 1 次\n");
    {
        uint32_t A = nxgal_tex_create(&ci), B = nxgal_tex_create(&ci);
        uint32_t ab[2] = {A, B}; nxgal_set_render_targets(ab, 2, 0); base_state(prog2);
        clear_full(0, 0, 0, 0, 0); clear_full(1, 0, 0, 0, 0);
        uint64_t e0 = g_gp_n[GP_RENC], m0 = g_pass_merged;
        set_quad(0.5f); set_color(1, 0, 0, 1); nxgal_draw(4, 1, 0, 0);
        uint32_t a0[2] = {A, 0}; nxgal_set_render_targets(a0, 2, 0);
        nxgal_set_program(prog); nxgal_set_texture_sampler(5, 0, g_white, g_smp); set_color(0, 1, 0, 1); nxgal_draw(4, 1, 0, 0);
        uint64_t enc = g_gp_n[GP_RENC] - e0, mg = g_pass_merged - m0;
        int na = count_px(A, green), nb = count_px(B, red);
        CHECK(na == 1024, "A 期望 1024 像素绿，实得 %d", na);
        CHECK(nb == 1024, "B 期望 1024 像素红（隐藏附件不被只写 A 的绘制改），实得 %d", nb);
        CHECK(enc == (off ? 2u : 1u), "渲染编码器期望 %d 个，实得 %llu", off ? 2 : 1, (unsigned long long)enc);
        CHECK(mg == (off ? 0u : 1u), "合遍次数期望 %d，实得 %llu", off ? 0 : 1, (unsigned long long)mg);
        nxgal_tex_release(A); nxgal_tex_release(B);
    }

    // 用例 5：开遍无深度、新组带深度不合（遍里没有深度附件）：[A] 无深度画绿 → [A] + D（清 1.0）z=0.5 红 Less → A 全红；编码器 2 个、合遍 0 次
    printf("· 开遍无深度 → 新组带深度不合遍：渲染编码器 2 个、合遍 0 次，A 全红\n");
    {
        uint32_t A = nxgal_tex_create(&ci), D = nxgal_tex_create(&di);
        nxgal_set_render_targets(&A, 1, 0); base_state(prog); clear_full(0, 0, 0, 0, 0);
        uint64_t e0 = g_gp_n[GP_RENC], m0 = g_pass_merged;
        set_quad(0.5f); set_color(0, 1, 0, 1); nxgal_draw(4, 1, 0, 0);
        nxgal_set_render_targets(&A, 1, D); clear_depth(1.0f);
        nxgal_depth_test dt = {1, 1, 2 /* Less */}; nxgal_set_depth_test(&dt);
        set_quad(0.5f); set_color(1, 0, 0, 1); nxgal_draw(4, 1, 0, 0);
        uint64_t enc = g_gp_n[GP_RENC] - e0, mg = g_pass_merged - m0;
        int na = count_px(A, red);
        CHECK(na == 1024, "A 期望 1024 像素红，实得 %d", na);
        CHECK(enc == 2u && mg == 0u, "期望渲染编码器 2 个 / 合遍 0 次，实得 %llu / %llu", (unsigned long long)enc, (unsigned long long)mg);
        nxgal_depth_test doff = {0, 0, 8}; nxgal_set_depth_test(&doff);
        nxgal_tex_release(A); nxgal_tex_release(D);
    }

    nxgal_shutdown();
    printf("%s：%d / %d 项通过（合遍%s）\n", g_fail ? "失败" : "通过", g_checks - g_fail, g_checks, off ? "关" : "开");
    return g_fail ? 1 : 0;
}
GAL_MTL4_ZONE_END
