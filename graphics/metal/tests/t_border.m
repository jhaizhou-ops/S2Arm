// 自定义采样器边框色（gal_border.m）端到端单测：手写 SPIR-V（tests/t_border_*.spvasm）→ 运行时现翻（带边框改写）→ 画 4×4 浮点目标 → 读回比手算期望。
// 只用 nxgal_* 公开接口（旧代码同样能编，供反证）。
// 期望（手算，不跑被测实现）：贴图 2×2 RGBA8 全部纹素 V = (204,154,100,50)/255，双线性、四向钳边框。
//   uv (0, 0.5)：x 方向 u·2 − 0.5 = −0.5 → 左采样点在界外（权重 0.5）、右在纹素 0；y 方向两行都在界内 → 结果 = 0.5·V + 0.5·边框色
//   gather 分量 1（G）同一坐标：Metal / Vulkan 次序 (i0,j1)(i1,j1)(i1,j0)(i0,j0)，i0 在界外 → (边框.G, V.G, V.G, 边框.G)
//   uv (−3, −3)：全在界外 → 边框色；gather 四个都是边框.G
//   边框色 C1 = (50,100,150,10)/255（主份透明黑、混合系数 = C1）；C2 = (200,220,240,250)/255（主份不透明白、系数 = 1 − C2）；
//   对照 C0 = 透明黑（三种之一，不模拟）→ 0.5·V
// 反证（旧代码：按最近三种之一）：C1 → 透明黑 → (102,77,50,25)、全界外 0；C2 → 不透明白 → (229.5,204.5,177.5,152.5)
#import <Metal/Metal.h>
#include "../gal_abi.h"
#include "../gal_formats.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int g_fail, g_checks;
#define CHECK(cond, ...) do { g_checks++; if (!(cond)) { g_fail++; printf("  ✗ " __VA_ARGS__); printf("\n"); } } while (0)
static void *slurp(const char *path, uint32_t *len) {
    FILE *f = fopen(path, "rb"); if (!f) return NULL; fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    void *p = malloc((size_t)n); if (fread(p, 1, (size_t)n, f) != (size_t)n) { free(p); fclose(f); return NULL; } fclose(f); *len = (uint32_t)n; return p;
}
static nxgal_tex_info ti(int w, int h, int fmt, int bpp) { nxgal_tex_info i = {w, h, 1, 1, 1, 1, 1, bpp, fmt, 0, 1, {2, 3, 4, 5}}; return i; }
static uint32_t buf_of(const void *p, int n) { uint32_t b = nxgal_buf_create(n, 0); nxgal_buf_set_data(b, 0, p, n); return b; }

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    if (nxgal_init(0)) return 2;
    char dir[1024]; snprintf(dir, sizeof dir, "%s", argv[0]); char *sl = strrchr(dir, '/'); if (sl) *sl = 0; else strcpy(dir, ".");
    char p[1100]; uint32_t lv = 0, lf = 0;
    snprintf(p, sizeof p, "%s/t_border_in/vs.spv", dir); void *vs = slurp(p, &lv);
    snprintf(p, sizeof p, "%s/t_border_in/fs.spv", dir); void *fs = slurp(p, &lf);
    if (!vs || !fs) { printf("  ✗ 读不到 %s/t_border_in/*.spv（make -C graphics/metal 生成）\n", dir); return 1; }
    printf("· 自定义边框色：双线性跨边界 / 全界外 / gather，主份透明黑与不透明白两种，另有三种之一对照\n");
    nxgal_shader sh[2] = {{vs, lv, 1}, {fs, lf, 5}};
    nxgal_res_desc d[2] = {{0, 19, 1, 0, 32}, {2, 128, 1, 4, 32}};
    uint32_t prog = nxgal_prog_create(sh, 2, d, 2, 0xf);
    int st = nxgal_prog_status(prog, 1);
    CHECK(st == 0, "建程序失败（状态 %d）：%s", st, nxgal_prog_last_error());
    if (st) return 1;

    const uint8_t V[4] = {204, 154, 100, 50};
    nxgal_tex_info t2 = ti(2, 2, F_R8G8B8A8Unorm, 4); uint32_t tex = nxgal_tex_create(&t2);
    uint8_t px[16]; for (int i = 0; i < 4; i++) memcpy(px + 4 * i, V, 4); nxgal_tex_set_data(tex, 0, 0, NULL, px, 16);
    nxgal_tex_info rt = ti(4, 4, F_R32G32B32A32Float, 16); uint32_t rts[2] = {nxgal_tex_create(&rt), nxgal_tex_create(&rt)};
    static const float tri[9] = {-1, -1, 0, 3, -1, 0, -1, 3, 0};
    uint32_t vb = buf_of(tri, sizeof tri);
    typedef struct { const char *n; float c[4]; float e1[4], g1[4], e2[4], g2[4]; } bc_t;
    // 期望单位：/255
    bc_t cs[] = {
        {"C1 (50,100,150,10)/255，主份透明黑", {50 / 255.f, 100 / 255.f, 150 / 255.f, 10 / 255.f}, {127, 127, 125, 30}, {100, 154, 154, 100}, {50, 100, 150, 10}, {100, 100, 100, 100}},
        {"C2 (200,220,240,250)/255，主份不透明白", {200 / 255.f, 220 / 255.f, 240 / 255.f, 250 / 255.f}, {202, 187, 170, 150}, {220, 154, 154, 220}, {200, 220, 240, 250}, {220, 220, 220, 220}},
        {"C0 透明黑（三种之一，不模拟）", {0, 0, 0, 0}, {102, 77, 50, 25}, {0, 154, 154, 0}, {0, 0, 0, 0}, {0, 0, 0, 0}},
    };
    for (int k = 0; k < 3; k++) {
        nxgal_sampler_info si = {2, 2, 1, 3, 3, 3, 0, 8, {cs[k].c[0], cs[k].c[1], cs[k].c[2], cs[k].c[3]}, 0, 1000, 0, 1};
        uint32_t smp = nxgal_sampler_create(&si);
        for (int u = 0; u < 2; u++) {
            float ub[16] = {0}; ub[0] = u ? -3 : 0; ub[1] = u ? -3 : 0.5f;
            uint32_t cb = buf_of(ub, sizeof ub);
            nxgal_set_render_targets(rts, 2, 0);
            nxgal_blend b = {0, {0, 0, 0, 0}, 1, 2, 1, 1, 2, 1}; for (int i = 0; i < 8; i++) nxgal_set_blend(i, &b);
            nxgal_depth_test dt = {0, 0, 8}; nxgal_set_depth_test(&dt);
            nxgal_stencil ss; memset(&ss, 0, sizeof ss); nxgal_set_stencil_test(&ss);
            nxgal_set_face_culling(0, 0x405); nxgal_set_front_face(0x901);
            nxgal_viewport vp = {0, 0, 4, 4, {0, 2, 4, 6}, 0, 1}; nxgal_set_viewports(&vp, 1);
            nxgal_rect sc = {0, 0, 4, 4}; nxgal_set_scissors(&sc, 1);
            uint32_t m[8] = {0xf, 0xf, 0xf, 0xf, 0xf, 0xf, 0xf, 0xf}; nxgal_set_color_masks(m, 8);
            nxgal_set_program(prog);
            nxgal_buf_assign ua = {19, {cb, 0, (int32_t)sizeof ub, 0}}; nxgal_set_uniform_buffers(&ua, 1);
            nxgal_set_texture_sampler(5, 128, tex, smp);
            nxgal_vbuf v = {{vb, 0, (int32_t)sizeof tri, 0}, 12, 0}; nxgal_set_vertex_buffers(&v, 1);
            nxgal_vattr at = {0, 0, 0, F_R32G32B32Float}; nxgal_set_vertex_attribs(&at, 1);
            nxgal_set_topology(4);
            nxgal_draw(3, 1, 0, 0);
            float o[2][64]; int rd = nxgal_tex_get_data(rts[0], 0, 0, o[0], sizeof o[0]) == (int)sizeof o[0] && nxgal_tex_get_data(rts[1], 0, 0, o[1], sizeof o[1]) == (int)sizeof o[1];
            const float *e = u ? cs[k].e2 : cs[k].e1, *g = u ? cs[k].g2 : cs[k].g1;
            int ok0 = rd, ok1 = rd; for (int c = 0; c < 4; c++) { ok0 &= fabsf(o[0][c] * 255 - e[c]) <= 1.5f; ok1 &= fabsf(o[1][c] * 255 - g[c]) <= 1.5f; }
            CHECK(ok0, "%s uv %s 采样：期望 %g %g %g %g 实得 %.1f %.1f %.1f %.1f（/255）", cs[k].n, u ? "(-3,-3)" : "(0,0.5)", e[0], e[1], e[2], e[3], o[0][0] * 255, o[0][1] * 255, o[0][2] * 255, o[0][3] * 255);
            CHECK(ok1, "%s uv %s gather G：期望 %g %g %g %g 实得 %.1f %.1f %.1f %.1f（/255）", cs[k].n, u ? "(-3,-3)" : "(0,0.5)", g[0], g[1], g[2], g[3], o[1][0] * 255, o[1][1] * 255, o[1][2] * 255, o[1][3] * 255);
        }
        nxgal_sampler_release(smp);
    }
    printf("%s：%d / %d 项通过\n", g_fail ? "失败" : "通过", g_checks - g_fail, g_checks);
    return g_fail != 0;
}
