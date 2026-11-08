// 逻辑运算单测（gal_state.m lop_apply，10-24 异度神剑3 报 0x1507 = OR）：Metal 片元没有逻辑运算；按 Vulkan 规则（Ryujinx Vulkan 后端同口径）只作用于非浮点 / 非 sRGB 目标。
// 程序 = 宽线单测的手写 SPIR-V（位置直通 + 片元写红）。期望（手算）：
//   ① NOOP（0x1505）画进 RGBA8：目标不变（红像素 0）——按写掩码 0 精确实现（旧代码：按复制画，整块红）；
//   ② COPY（0x1503）画进 RGBA8：整块红（正对照）；
//   ③ OR（0x1507）画进 RGBA16F：浮点目标逻辑运算不生效 = 复制，不计「未实现」（计数不变）；
//   ④ OR 画进 RGBA8：未实现、按复制画，计数 +1 以上。
// 整数目标真实现（gal_logicop.m 的 s<键>_lo 入口，帧缓冲读取仿真；手写整数输出片元 tests/t_lop_*.spvasm）。先清成已知位模式 A，再画常量 B，逐像素核：
//   ⑤ R32Uint × 16 种运算（0x1500–0x150F）：每像素 = GL 定义（下面 gl_lop，按 GL 规范逐条手写，不调被测 MSL）作用在 (B, A) 上；
//      COPY / NOOP 不走 _lo（照旧复制 / 写掩码 0），其余 14 种走 _lo：「未实现」计数不变、仿真键计数 +1；
//   ⑥ RG32Uint × 16 种：两个分量各自核；⑦ R32Sint（有符号输出）× 16 种：按位同上（A、B 都是负数，核符号位）；
//   ⑧ 原入口函数体里有 discard_fragment（gl_FragCoord.x < 16 丢弃）：OR 下左半 = A（丢弃、不写），右半 = A | B；
//   ⑨ unorm 换算（辅助函数 unorm 分支，_lo 本次不对 unorm 出）：计算核调 s2a_lop_apply(float4…)，R8Unorm（位宽 8,0,0,0）与 RGBA8Unorm（8,8,8,8）
//      × 16 种运算 × 若干字节对：round(结果 × 255) = gl_lop(S, D) & 0xff；R8Unorm 的 g/b/a 分量（位宽 0）原样 = 源。
//   ⑩ OR 画进 RGBA8（unorm）仍按复制画并计未实现（总指挥 10-24：unorm / snorm 照旧报红）——即 ④。
#import <Metal/Metal.h>
#include "../gal_abi.h"
#include "../gal_internal.h"
#include "../gal_formats.h"
#include <libgen.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

GAL_MTL4_ZONE_BEGIN
static int g_fail, g_checks;
#define CHECK(cond, ...) do { g_checks++; if (!(cond)) { g_fail++; printf("  ✗ " __VA_ARGS__); printf("\n"); } else printf("  ✓ " __VA_ARGS__), printf("\n"); } while (0)
static char g_dir[1024];
static uint8_t *load(const char *name, uint32_t *len) {
    char p[1200]; snprintf(p, sizeof p, "%s/%s.spv", g_dir, name);
    FILE *f = fopen(p, "rb"); if (!f) { printf("读不了 %s\n", p); exit(2); }
    fseek(f, 0, SEEK_END); long l = ftell(f); fseek(f, 0, SEEK_SET);
    uint8_t *b = malloc((size_t)l); if (fread(b, 1, (size_t)l, f) != (size_t)l) exit(2);
    fclose(f); *len = (uint32_t)l; return b;
}
static uint32_t g_rt, g_prog;
extern uint64_t g_lop_unimpl_draws, g_lop_emu_keys;
// GL 逻辑运算定义（OpenGL 4.6 表 17.3，s = 源（片元）、d = 目标）
static uint32_t gl_lop(int op, uint32_t s, uint32_t d) {
    switch (op) {
        case 0x1500: return 0;          case 0x1501: return s & d;    case 0x1502: return s & ~d;   case 0x1503: return s;
        case 0x1504: return ~s & d;     case 0x1505: return d;        case 0x1506: return s ^ d;    case 0x1507: return s | d;
        case 0x1508: return ~(s | d);   case 0x1509: return ~(s ^ d); case 0x150A: return ~d;       case 0x150B: return s | ~d;
        case 0x150C: return ~s;         case 0x150D: return ~s | d;   case 0x150E: return ~(s & d); default: return 0xffffffffu;
    }
}
static float g_clear[4];
static void setup(void) {
    float *c = g_clear; nxgal_set_render_targets(&g_rt, 1, 0);
    nxgal_rect full = {0, 0, 0xffff, 0xffff}; nxgal_set_scissors(&full, 1); nxgal_clear_color(0, 0, 1, 0xf, c);
    nxgal_blend b = {0, {0, 0, 0, 0}, 1, 2, 1, 1, 2, 1}; for (int i = 0; i < 8; i++) nxgal_set_blend(i, &b);
    nxgal_depth_test dt = {0, 0, 8}; nxgal_set_depth_test(&dt);
    nxgal_stencil ss; memset(&ss, 0, sizeof ss); nxgal_set_stencil_test(&ss);
    nxgal_set_face_culling(0, 0x405); nxgal_set_front_face(0x901);
    nxgal_viewport vp = {0, 0, 32, 32, {0, 2, 4, 6}, 0, 1}; nxgal_set_viewports(&vp, 1);
    nxgal_rect sc = {0, 0, 32, 32}; nxgal_set_scissors(&sc, 1);
    uint32_t m[8] = {0xf, 0xf, 0xf, 0xf, 0xf, 0xf, 0xf, 0xf}; nxgal_set_color_masks(m, 8);
    nxgal_set_program(g_prog);
    float xyz[12] = {-1, -1, 0.5f, 1, -1, 0.5f, 1, 1, 0.5f, -1, 1, 0.5f};
    uint32_t vb = nxgal_buf_create(48, 0); nxgal_buf_set_data(vb, 0, xyz, 48);
    nxgal_vbuf v = {{vb, 0, 48, 0}, 12, 0}; nxgal_set_vertex_buffers(&v, 1);
    nxgal_vattr at = {0, 0, 0, F_R32G32B32Float}; nxgal_set_vertex_attribs(&at, 1); nxgal_set_topology(7 /* Quads */);
}
static int red_pixels(void) {
    static uint8_t px[32 * 32 * 4]; if (nxgal_tex_get_data(g_rt, 0, 0, px, sizeof px) != (int)sizeof px) return -1;
    int n = 0; for (int i = 0; i < 32 * 32; i++) n += px[i * 4] == 255 && px[i * 4 + 1] == 0 && px[i * 4 + 3] == 255;
    return n;
}

static void into(int fmt, int bpp) { if (g_rt) nxgal_tex_release(g_rt); nxgal_tex_info ri = {32, 32, 1, 1, 1, 1, 1, bpp, fmt, 0, 1, {2, 3, 4, 5}}; g_rt = nxgal_tex_create(&ri); }
static int red16(void) {
    static uint16_t px[32 * 32 * 4]; if (nxgal_tex_get_data(g_rt, 0, 0, px, sizeof px) != (int)sizeof px) return -1;
    int n = 0; for (int i = 0; i < 32 * 32; i++) n += px[i * 4] == 0x3c00 && px[i * 4 + 1] == 0;
    return n;
}
static uint32_t mkprog(const char *fsname) {
    char d0[1024]; snprintf(d0, sizeof d0, "%s", g_dir);
    uint32_t lv, lf; uint8_t *vs = load("vs", &lv);
    char *sl = strrchr(g_dir, '/'); snprintf(sl + 1, sizeof g_dir - (size_t)(sl + 1 - g_dir), "t_lop_in");
    uint8_t *fs = load(fsname, &lf); snprintf(g_dir, sizeof g_dir, "%s", d0);
    nxgal_shader sh[2] = {{vs, lv, 1}, {fs, lf, 5}};
    uint32_t p = nxgal_prog_create(sh, 2, NULL, 0, 0xf); free(vs); free(fs);
    int st = nxgal_prog_status(p, 1); CHECK(st == 0, "建程序 %s（状态 %d）%s", fsname, st, st ? nxgal_prog_last_error() : "");
    gal_prog *pg = gal_prog_get(p); CHECK(pg && pg->fn_lo, "程序 %s 有逻辑运算入口 _lo", fsname);
    return st ? 0 : p;
}
static uint32_t g_px[32 * 32 * 2];
// 画一次：格式 fmt（bpp 字节 / 像素），先清成 a0/a1，开运算 op 画常量；读回到 g_px
// 整数目标的清屏值按位模式传（nxgal_clear_color：整数格式取 rgba 的位，同 Ryujinx 把整数清屏值按位塞进 ColorF）
static int draw_once(uint32_t prog, int fmt, int bpp, uint32_t a0, uint32_t a1, int op) {
    into(fmt, bpp); memcpy(&g_clear[0], &a0, 4); memcpy(&g_clear[1], &a1, 4); g_clear[2] = g_clear[3] = 0;
    uint32_t keep = g_prog; g_prog = prog; setup(); g_prog = keep;
    nxgal_set_logic_op(1, op); nxgal_draw(4, 1, 0, 0); nxgal_set_logic_op(0, 0x1503);
    int n = 32 * 32 * bpp; return nxgal_tex_get_data(g_rt, 0, 0, g_px, (uint32_t)n) == n;
}
// 16 种运算逐像素核：ncomp 个分量，a[] 为清屏位模式、b[] 为片元常量；x0 起的列（丢弃例只核右半，左半另核 = A）
static void sweep(const char *what, uint32_t prog, int fmt, int bpp, int ncomp, const uint32_t a[2], const uint32_t b[2]) {
    for (int op = 0x1500; op <= 0x150F; op++) {
        uint64_t u0 = g_lop_unimpl_draws, e0 = g_lop_emu_keys;
        if (!draw_once(prog, fmt, bpp, a[0], a[1], op)) { CHECK(0, "%s 运算 %#x 读回失败", what, op); continue; }
        int bad = 0; uint32_t got0 = 0, want0 = 0;
        for (int i = 0; i < 32 * 32; i++) for (int c = 0; c < ncomp; c++) {
            uint32_t got = g_px[i * ncomp + c], want = gl_lop(op, b[c], a[c]);
            if (got != want) { if (!bad) { got0 = got; want0 = want; } bad++; }
        }
        int emu = op != 0x1503 && op != 0x1505;
        CHECK(!bad && g_lop_unimpl_draws == u0 && (emu ? g_lop_emu_keys > e0 : g_lop_emu_keys == e0),
              "%s 运算 %#x：%d 分量 × 1024 像素错 %d（首例 实 %08x / 期望 %08x），未实现计数增量 %llu（期望 0），仿真键增量 %llu（期望 %s）",
              what, op, ncomp, bad, got0, want0, (unsigned long long)(g_lop_unimpl_draws - u0), (unsigned long long)(g_lop_emu_keys - e0), emu ? "≥1" : "0");
    }
}
// ⑨ unorm 换算：计算核直接调辅助函数（gal_logicop_helpers），不经渲染路径
static void unorm_check(void) {
    NSString *src = [NSString stringWithFormat:@"#include <metal_stdlib>\nusing namespace metal;\n%@\n"
        "kernel void k(constant S2ALop* L [[buffer(0)]], const device float4* s [[buffer(1)]], const device float4* d [[buffer(2)]], device float4* o [[buffer(3)]], uint i [[thread_position_in_grid]]) {\n"
        "    o[i] = s2a_lop_apply(s[i], d[i], L[i / 64u], 0u);\n}\n", @(gal_logicop_helpers())];
    NSError *err = nil; id<MTLLibrary> lib = [g_gdev newLibraryWithSource:src options:[MTLCompileOptions new] error:&err];
    CHECK(lib != nil, "编 unorm 换算计算核 %s", lib ? "" : err.localizedDescription.UTF8String); if (!lib) return;
    id<MTLComputePipelineState> ps = [g_gdev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&err]; if (!ps) { CHECK(0, "建计算管线"); return; }
    // 32 组 = 2 种格式 × 16 种运算，每组 64 个字节对（S, D 取 0、1、0x55、0xAA、0xFF、0x80、0x7F、0x3C 两两组合）
    enum { NG = 32, NP = 64 }; static const uint8_t v[8] = {0, 1, 0x55, 0xAA, 0xFF, 0x80, 0x7F, 0x3C};
    typedef struct { uint32_t op, kind[8], bits[8]; } lopp; lopp L[NG]; memset(L, 0, sizeof L);
    static float s[NG * NP][4], d[NG * NP][4];
    for (int g = 0; g < NG; g++) {
        L[g].op = (uint32_t)(g % 16); L[g].kind[0] = 3; L[g].bits[0] = g < 16 ? 8u : 0x08080808u;
        for (int j = 0; j < NP; j++) for (int c = 0; c < 4; c++) {
            uint8_t S = v[(j + c) % 8], D = v[(j / 8 + c * 3) % 8];
            s[g * NP + j][c] = S / 255.0f; d[g * NP + j][c] = D / 255.0f;
        }
    }
    id<MTLBuffer> bl = [g_gdev newBufferWithBytes:L length:sizeof L options:MTLResourceStorageModeShared];
    id<MTLBuffer> bs = [g_gdev newBufferWithBytes:s length:sizeof s options:MTLResourceStorageModeShared];
    id<MTLBuffer> bd = [g_gdev newBufferWithBytes:d length:sizeof d options:MTLResourceStorageModeShared];
    id<MTLBuffer> bo = [g_gdev newBufferWithLength:sizeof s options:MTLResourceStorageModeShared];
    id<MTLCommandQueue> q = [g_gdev newCommandQueue]; id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    [ce setComputePipelineState:ps]; [ce setBuffer:bl offset:0 atIndex:0]; [ce setBuffer:bs offset:0 atIndex:1]; [ce setBuffer:bd offset:0 atIndex:2]; [ce setBuffer:bo offset:0 atIndex:3];
    [ce dispatchThreads:MTLSizeMake(NG * NP, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)]; [ce endEncoding]; [cb commit]; [cb waitUntilCompleted];
    const float (*o)[4] = bo.contents;
    for (int f = 0; f < 2; f++) {
        int bad = 0, pass = 0, n = 0; char ex[160] = "";
        for (int g = f * 16; g < f * 16 + 16; g++) for (int j = 0; j < NP; j++) for (int c = 0; c < 4; c++) {
            int k = g * NP + j; uint8_t S = (uint8_t)lroundf(s[k][c] * 255.0f), D = (uint8_t)lroundf(d[k][c] * 255.0f);
            if (f == 0 && c > 0) { n++; if (o[k][c] != s[k][c]) { if (!pass++) snprintf(ex, sizeof ex, "R8 分量 %d 实 %g 期望原样 %g", c, o[k][c], s[k][c]); } continue; }
            uint32_t want = gl_lop(0x1500 + g % 16, S, D) & 0xff; long got = lroundf(o[k][c] * 255.0f); n++;
            if (got != (long)want) { if (!bad++ && !*ex) snprintf(ex, sizeof ex, "运算 %#x S %02x D %02x 实 %ld 期望 %u", 0x1500 + g % 16, S, D, got, want); }
        }
        CHECK(!bad && !pass, "%s × 16 种运算：%d 个分量，换算错 %d、位宽 0 分量没原样 %d %s", f ? "RGBA8Unorm（8,8,8,8）" : "R8Unorm（8,0,0,0）", n, bad, pass, ex);
    }
}
int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    (void)argc; char exe[1024]; snprintf(exe, sizeof exe, "%s", argv[0]); snprintf(g_dir, sizeof g_dir, "%s/t_wline_in", dirname(exe));
    setenv("NXGAL_BOUNDS_COUNT", "0", 1);
    if (nxgal_init(0)) return 2;
    uint32_t lv, lf; uint8_t *vs = load("vs", &lv), *fs = load("fs", &lf);
    nxgal_shader sh[2] = {{vs, lv, 1}, {fs, lf, 5}};
    g_prog = nxgal_prog_create(sh, 2, NULL, 0, 0xf); free(vs); free(fs);
    int st = nxgal_prog_status(g_prog, 1); CHECK(st == 0, "建程序（状态 %d）%s", st, st ? nxgal_prog_last_error() : "");
    if (st) return 1;
    printf("· ① NOOP 画进 RGBA8\n");
    into(F_R8G8B8A8Unorm, 4); setup(); nxgal_set_logic_op(1, 0x1505); nxgal_draw(4, 1, 0, 0);
    int r = red_pixels(); CHECK(r == 0, "目标不变：红像素期望 0，实得 %d", r);
    printf("· ② COPY 画进 RGBA8（正对照）\n");
    into(F_R8G8B8A8Unorm, 4); setup(); nxgal_set_logic_op(1, 0x1503); nxgal_draw(4, 1, 0, 0);
    r = red_pixels(); CHECK(r == 32 * 32, "整块红：期望 1024，实得 %d", r);
    printf("· ③ OR 画进 RGBA16F\n");
    uint64_t c0 = g_lop_unimpl_draws;
    into(F_R16G16B16A16Float, 8); setup(); nxgal_set_logic_op(1, 0x1507); nxgal_draw(4, 1, 0, 0);
    r = red16(); CHECK(r == 32 * 32 && g_lop_unimpl_draws == c0, "浮点目标照复制写、不计未实现：红 %d / 1024，计数增量 %llu（期望 0）", r, (unsigned long long)(g_lop_unimpl_draws - c0));
    printf("· ④ OR 画进 RGBA8\n");
    into(F_R8G8B8A8Unorm, 4); setup(); nxgal_set_logic_op(1, 0x1507); nxgal_draw(4, 1, 0, 0);
    CHECK(g_lop_unimpl_draws > c0, "非浮点目标记未实现：计数增量 %llu（期望 ≥1）", (unsigned long long)(g_lop_unimpl_draws - c0));
    // 读回同时收掉当前遍：不读回就换目标时，into() 释放的旧目标编号被新贴图复用、遍没重开，下一次清屏 + 绘制落到旧贴图上（10-24 实测：⑤ 首次读回全 0）
    r = red_pixels(); CHECK(r == 32 * 32, "unorm 目标照复制画：红 %d / 1024", r);
    CHECK(!gal_prog_get(g_prog)->fn_lo, "浮点输出程序没有 _lo 入口（只给整数输出的片元出）");
    uint32_t pu = mkprog("fsu"), pi = mkprog("fsi"), pd = mkprog("fsd");
    if (!pu || !pi || !pd) { printf("失败：建程序\n"); return 1; }
    // A：清屏位模式；B：片元常量（spvasm 里）
    printf("· ⑤ R32Uint × 16 种运算\n");
    { uint32_t a[2] = {0xC3F0CC55u, 0}, b[2] = {0x0F0F3C33u, 0xA5A5A5A5u}; sweep("R32Uint", pu, F_R32Uint, 4, 1, a, b); }
    printf("· ⑥ RG32Uint × 16 种运算\n");
    { uint32_t a[2] = {0xC3F0CC55u, 0x9A123456u}, b[2] = {0x0F0F3C33u, 0xA5A5A5A5u}; sweep("RG32Uint", pu, F_R32G32Uint, 8, 2, a, b); }
    printf("· ⑦ R32Sint（有符号输出）× 16 种运算\n");
    { uint32_t a[2] = {(uint32_t)-1193047, 0}, b[2] = {(uint32_t)-252645136, 305419896u}; sweep("R32Sint", pi, F_R32Sint, 4, 1, a, b); }
    printf("· ⑧ 原函数体带 discard_fragment：OR 进 R32Uint\n");
    if (draw_once(pd, F_R32Uint, 4, 0xC3F0CC55u, 0, 0x1507)) {
        int badl = 0, badr = 0;
        for (int y = 0; y < 32; y++) for (int x = 0; x < 32; x++) { uint32_t g = g_px[y * 32 + x]; if (x < 16) badl += g != 0xC3F0CC55u; else badr += g != (0xC3F0CC55u | 0x0F0F3C33u); }
        CHECK(!badl && !badr, "左半丢弃 = A（错 %d / 512），右半 = A|B = %08x（错 %d / 512）", badl, 0xC3F0CC55u | 0x0F0F3C33u, badr);
    } else CHECK(0, "丢弃例读回失败");
    printf("· ⑨ unorm 换算（辅助函数）\n");
    unorm_check();
    nxgal_shutdown();
    printf("%s：%d / %d 项通过\n", g_fail ? "失败" : "通过", g_checks - g_fail, g_checks);
    return g_fail ? 1 : 0;
}
GAL_MTL4_ZONE_END
