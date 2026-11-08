// 无片元程序走基础管线单测（gal_state.m pso_build，10-21 首局根治 ③）：只有顶点阶段的程序（无片元、光栅化开）也先建「颜色留空」的基础管线，再按通道颜色格式特化；
//   原先带着本次颜色格式整条现建，出包归档永远对不上（怪猎首局 39 条「片元 -」现建）。
// 程序用手写 SPIR-V 顶点着色器（tests/t_fbr_vsp，与 t_fbfetch 同一份），只建顶点阶段。
// 期望（手算）：同一程序先后画进 RGBA8、RGBA16F 两种颜色格式的通道 → 现建只 1 条（基础管线，两次绘制共用），两次都不报错；
//   旧代码（无片元不走特化）每种格式整条现建一次 = 2 条。对照组：NXGAL_PSO_SPECIALIZE=0（关特化）同样两次 = 2 条。
#import <Metal/Metal.h>
#include "../gal_abi.h"
#include "../gal_internal.h"
#include "../gal_formats.h"
#include <libgen.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

GAL_MTL4_ZONE_BEGIN
static int g_fail, g_checks;
#define CHECK(cond, ...) do { g_checks++; if (!(cond)) { g_fail++; printf("  ✗ " __VA_ARGS__); printf("\n"); } } while (0)

static char g_dir[1024];
static uint8_t *load(const char *name, uint32_t *len) {
    char p[1200]; snprintf(p, sizeof p, "%s/%s.spv", g_dir, name);
    FILE *f = fopen(p, "rb"); if (!f) { printf("读不了 %s\n", p); exit(2); }
    fseek(f, 0, SEEK_END); long l = ftell(f); fseek(f, 0, SEEK_SET);
    uint8_t *b = malloc((size_t)l); if (fread(b, 1, (size_t)l, f) != (size_t)l) exit(2);
    fclose(f); *len = (uint32_t)l; return b;
}
static nxgal_tex_info ti(int w, int h, int fmt, int bpp) { nxgal_tex_info i = {w, h, 1, 1, 1, 1, 1, bpp, fmt, 0, 1, {2, 3, 4, 5}}; return i; }
static void set_ubo(void) { float c[4] = {1, 1, 1, 1}; uint32_t u = nxgal_buf_create(16, 0); nxgal_buf_set_data(u, 0, c, 16); nxgal_buf_assign a0 = {0, {u, 0, 16, 0}}; nxgal_set_uniform_buffers(&a0, 1); }
static void set_quad(void) {
    float v[12] = {-1, -1, 0.5f, 1, -1, 0.5f, 1, 1, 0.5f, -1, 1, 0.5f};
    uint32_t b = nxgal_buf_create(48, 0); nxgal_buf_set_data(b, 0, v, 48);
    nxgal_vbuf vb = {{b, 0, 48, 0}, 12, 0}; nxgal_set_vertex_buffers(&vb, 1);
    nxgal_vattr at = {0, 0, 0, 33}; nxgal_set_vertex_attribs(&at, 1); nxgal_set_topology(7 /* Quads */);
}
static void base_state(void) {
    nxgal_blend b = {0, {0, 0, 0, 0}, 1, 2, 1, 1, 2, 1}; for (int i = 0; i < 8; i++) nxgal_set_blend(i, &b);
    nxgal_depth_test d = {0, 0, 8}; nxgal_set_depth_test(&d);
    nxgal_stencil s; memset(&s, 0, sizeof s); nxgal_set_stencil_test(&s);
    nxgal_set_face_culling(0, 0x405); nxgal_set_front_face(0x901);
    nxgal_viewport vp = {0, 0, 32, 32, {0, 2, 4, 6}, 0, 1}; nxgal_set_viewports(&vp, 1);
    nxgal_rect sc = {0, 0, 32, 32}; nxgal_set_scissors(&sc, 1);
    uint32_t m[8] = {0xf, 0xf, 0xf, 0xf, 0xf, 0xf, 0xf, 0xf}; nxgal_set_color_masks(m, 8);
}
// 画一次铺满四边形到新目标（fmt / bpp），等 GPU 做完
static void draw_into(uint32_t prog, int fmt, int bpp) {
    nxgal_tex_info ci = ti(32, 32, fmt, bpp); uint32_t A = nxgal_tex_create(&ci);
    nxgal_set_render_targets(&A, 1, 0);
    float z[4] = {0, 0, 0, 0}; nxgal_clear_color(0, 0, 1, 0xf, z);
    base_state(); set_ubo(); set_quad(); nxgal_set_program(prog);
    nxgal_draw(4, 1, 0, 0);
    static uint8_t rb[32 * 32 * 8]; nxgal_tex_get_data(A, 0, 0, rb, 32 * 32 * bpp); nxgal_tex_release(A);
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    (void)argc; char exe[1024]; snprintf(exe, sizeof exe, "%s", argv[0]); snprintf(g_dir, sizeof g_dir, "%s/t_fbr_in", dirname(exe));
    setenv("NXGAL_BOUNDS_COUNT", "0", 1);
    if (argc > 1 && !strcmp(argv[1], "--nospec")) setenv("NXGAL_PSO_SPECIALIZE", "0", 1);
    int spec = !(argc > 1 && !strcmp(argv[1], "--nospec"));
    if (nxgal_init(0)) return 2;
    printf("· 只有顶点阶段的程序画进 RGBA8、RGBA16F 两种通道（%s）\n", spec ? "特化开（缺省）" : "对照：关特化");
    uint32_t vl; uint8_t *v = load("vsp", &vl);
    nxgal_shader sh[1] = {{v, vl, 1}};
    uint32_t P = nxgal_prog_create(sh, 1, NULL, 0, 0xff); free(v);
    int st = 2; for (int i = 0; i < 500 && P && (st = nxgal_prog_status(P, 0)) == 2; i++) usleep(10000);
    CHECK(P && st == 0, "只有顶点阶段的程序建不出（状态 %d：%s）", st, nxgal_prog_last_error());
    uint64_t s0[4], s1[4]; nxgal_pso_cache_stats(s0);
    draw_into(P, F_R8G8B8A8Unorm, 4); draw_into(P, F_R16G16B16A16Float, 8);
    nxgal_pso_cache_stats(s1);
    uint64_t built = s1[1] - s0[1], want = spec ? 1 : 2;
    CHECK(built == want, "现建期望 %llu 条（%s），实得 %llu 条", (unsigned long long)want, spec ? "基础管线一条、两种格式各特化" : "关特化：每种格式整条现建", (unsigned long long)built);
    nxgal_shutdown();
    printf("%s：%d / %d 项通过\n", g_fail ? "失败" : "通过", g_checks - g_fail, g_checks);
    return g_fail ? 1 : 0;
}
GAL_MTL4_ZONE_END
