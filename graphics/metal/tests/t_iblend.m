// 整数目标不混合单测（gal_state.m gal_fmt_is_int，10-24 异度神剑3 真机首局 abort）：游戏在 RG32Uint / R32Uint 目标上留着混合使能位，
//   Metal 建管线时描述符校验断言「pixelformat … is not blendable」→ abort（iPhone 上关不掉）。Vulkan 规定整数附件上的混合被忽略。
// 程序 = 宽线顶点（位置直通）+ 手写整数输出片元（tests/t_iblend_fs：o0 = (0x5A, 0xA5, 0, 0)）。期望（手算）：
//   ① R32Uint 目标、混合开（加法 One/One）：管线建得出，整块 = 0x5A（混合被忽略，不是 0x5A + 清屏值 7）
//   ② RG32Uint 目标同上：整块 = (0x5A, 0xA5)
//   ②b R32Uint、alpha-to-coverage + alpha-to-one 开：关掉后照写 0x5A（校验层下 19 种整数格式开这两项都断言）
//   ③ 两次都记「整数目标忽略混合」计数 ≥ 1
//   ④ 子进程走整条现建（NXGAL_PSO_SPECIALIZE=0）+ 校验层，不断言（旧代码：validateWithDevice failed assertion … not blendable → abort）
// 开 MTL_DEBUG_LAYER=1 跑（旧代码在校验层下建管线报错 / 断言）
#import <Metal/Metal.h>
#include "../gal_abi.h"
#include "../gal_internal.h"
#include "../gal_formats.h"
#include <libgen.h>
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
extern uint64_t g_int_noblend;
static void setup(void) {
    float c[4] = {0, 0, 0, 0}; nxgal_set_render_targets(&g_rt, 1, 0);
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
static void clear_u(uint32_t v) { float c[4]; uint32_t u[4] = {v, v, v, v}; memcpy(c, u, 16); nxgal_rect full = {0, 0, 0xffff, 0xffff}; nxgal_set_scissors(&full, 1); nxgal_clear_color(0, 0, 1, 0xf, c); }
int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    (void)argc; char exe[1024], fsd[1024]; snprintf(exe, sizeof exe, "%s", argv[0]); snprintf(g_dir, sizeof g_dir, "%s/t_wline_in", dirname(exe)); snprintf(fsd, sizeof fsd, "%s/t_iblend_in", dirname(exe));
    setenv("NXGAL_BOUNDS_COUNT", "0", 1);
    if (nxgal_init(0)) return 2;
    uint32_t lv, lf; uint8_t *vs = load("vs", &lv); snprintf(g_dir, sizeof g_dir, "%s", fsd); uint8_t *fs = load("fs", &lf);
    nxgal_shader sh[2] = {{vs, lv, 1}, {fs, lf, 5}};
    g_prog = nxgal_prog_create(sh, 2, NULL, 0, 0xf); free(vs); free(fs);
    int st = nxgal_prog_status(g_prog, 1); CHECK(st == 0, "建程序（状态 %d）%s", st, st ? nxgal_prog_last_error() : "");
    if (st) return 1;
    nxgal_blend add = {1, {0, 0, 0, 0}, 1, 2, 2, 1, 2, 2};   // 开混合：Add、One / One（GAL 枚举：运算 Add = 1，因子 Zero = 1、One = 2）
    uint64_t c0 = g_int_noblend;
    printf("· ① R32Uint 混合开\n");
    into(F_R32Uint, 4); setup(); clear_u(7); for (int i = 0; i < 8; i++) nxgal_set_blend(i, &add); nxgal_draw(4, 1, 0, 0);
    static uint32_t px[32 * 32 * 4]; int n = 0;
    if (nxgal_tex_get_data(g_rt, 0, 0, px, 32 * 32 * 4) == 32 * 32 * 4) for (int i = 0; i < 32 * 32; i++) n += px[i] == 0x5A;
    CHECK(n == 32 * 32, "整块 = 0x5A（混合被忽略）：%d / 1024", n);
    printf("· ② RG32Uint 混合开\n");
    into(F_R32G32Uint, 8); setup(); clear_u(7); for (int i = 0; i < 8; i++) nxgal_set_blend(i, &add); nxgal_draw(4, 1, 0, 0);
    n = 0; if (nxgal_tex_get_data(g_rt, 0, 0, px, 32 * 32 * 8) == 32 * 32 * 8) for (int i = 0; i < 32 * 32; i++) n += px[i * 2] == 0x5A && px[i * 2 + 1] == 0xA5;
    CHECK(n == 32 * 32, "整块 = (0x5A, 0xA5)：%d / 1024", n);
    printf("· ②b R32Uint、混合关、alpha-to-coverage 开（整数 0 号目标：关掉）\n");
    nxgal_blend off = {0, {0, 0, 0, 0}, 1, 2, 1, 1, 2, 1};
    into(F_R32Uint, 4); setup(); clear_u(7); for (int i = 0; i < 8; i++) nxgal_set_blend(i, &off); nxgal_set_multisample(1, 0, 1); nxgal_draw(4, 1, 0, 0); nxgal_set_multisample(0, 0, 0);
    n = 0; if (nxgal_tex_get_data(g_rt, 0, 0, px, 32 * 32 * 4) == 32 * 32 * 4) for (int i = 0; i < 32 * 32; i++) n += px[i] == 0x5A;
    CHECK(n == 32 * 32, "a2c / a2one 开时整块 = 0x5A：%d / 1024", n);
    CHECK(g_int_noblend > c0, "记「整数目标忽略混合」：增量 %llu（期望 ≥1）", (unsigned long long)(g_int_noblend - c0));
    nxgal_shutdown();
    // ④ 整条现建路径（关特化）+ Metal 校验层：iPhone 设备归档后台编的就是整条描述，旧代码在这条路上断言 abort（Mac 只在校验层下报）
    if (!(argc > 1 && !strcmp(argv[1], "--full"))) {
        char cmd[2048]; snprintf(cmd, sizeof cmd, "NXGAL_PSO_SPECIALIZE=0 MTL_DEBUG_LAYER=1 '%s' --full > /dev/null 2>&1", argv[0]);
        int rc = system(cmd); CHECK(rc == 0, "④ 整条现建 + 校验层不断言（rc %d；旧代码 abort）", rc);
    }
    printf("%s：%d / %d 项通过\n", g_fail ? "失败" : "通过", g_checks - g_fail, g_checks);
    return g_fail ? 1 : 0;
}
GAL_MTL4_ZONE_END
