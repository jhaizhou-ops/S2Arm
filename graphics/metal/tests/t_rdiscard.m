// 光栅化丢弃单测（gal_state.m pso_desc / gal_state_apply_dynamic，10-24 异度神剑3）：
//   Metal 关光栅化（rasterizationEnabled = NO）要求顶点函数返回 void，而翻译出的顶点函数都返回结构体（位置等输出），旧代码这类管线一律建失败、绘制被跳过。
//   现做法：管线照开光栅化、不带片元函数、颜色写掩码全 0；绘制时剪裁全部置空——顶点照跑（副作用保留），不出片元（颜色 / 深度 / 模板 / 遮挡计数都不动）。
// 程序 = 宽线单测的手写 SPIR-V（tests/t_wline_*：位置直通 + 片元写红）。期望（手算）：
//   ① 开丢弃时管线建得出（旧代码：建失败，返回空）；
//   ② 开丢弃画铺满四边形：目标保持清屏的 0；
//   ③ 关丢弃再画同一四边形：整块变红（正对照：四边形确实盖满、剪裁已恢复）。
#import <Metal/Metal.h>
#include "../gal_abi.h"
#include "../gal_internal.h"
#include "../gal_draw_internal.h"
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
    nxgal_tex_info ri = {32, 32, 1, 1, 1, 1, 1, 4, F_R8G8B8A8Unorm, 0, 1, {2, 3, 4, 5}}; g_rt = nxgal_tex_create(&ri);

    printf("· ① 开丢弃建管线\n");
    setup(); nxgal_set_rasterizer_discard(1);
    int pend = 0; const gal_prog *pg = gal_prog_get_draw(g_prog, &pend); uint8_t crm = 0;
    id p = pg ? gal_pso_get(pg, &crm, NULL) : nil;
    for (int i = 0; i < 300 && !p && gal_pso_pending(); i++) { usleep(10000); p = gal_pso_get(pg, &crm, NULL); }
    CHECK(p != nil, "光栅化丢弃时管线建得出（旧代码：顶点函数返回结构体，建失败）");

    printf("· ② 开丢弃画铺满四边形\n");
    nxgal_draw(4, 1, 0, 0);
    int r = red_pixels(); CHECK(r == 0, "目标保持清屏：红像素期望 0，实得 %d", r);

    printf("· ③ 关丢弃再画（正对照）\n");
    nxgal_set_rasterizer_discard(0); nxgal_draw(4, 1, 0, 0);
    r = red_pixels(); CHECK(r == 32 * 32, "整块变红：期望 1024，实得 %d", r);

    nxgal_shutdown();
    printf("%s：%d / %d 项通过\n", g_fail ? "失败" : "通过", g_checks - g_fail, g_checks);
    return g_fail ? 1 : 0;
}
GAL_MTL4_ZONE_END
