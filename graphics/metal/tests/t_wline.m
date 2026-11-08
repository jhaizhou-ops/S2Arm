// 宽线展开（gal_wline.m）端到端单测：手写 SPIR-V（tests/t_wline_*.spvasm）→ 运行时现翻（带 s<键>_wl 入口）→ 线拓扑 + 线宽画到 32×32 → 数红像素。
// 只用 nxgal_* 公开接口（旧代码同样能编，供反证）。期望（手算，不跑被测实现；矩形线，像素中心落在矩形内才算）：
//   A 条带非索引 (−0.5,0)→(0.5,0) 线宽 4：x 8..24（16 列）× y 16±2（14..18，4 行）= 64；线宽 1（不展开）= 16
//   B 列表 16 位索引 {1,0}，(0,−0.5)/(0,0.5) 竖线、线宽 2、基顶点 1（顶点缓冲前面垫一个顶点）：x 16±1（2 列）× y 8..24（16 行）= 32
//   C 环 4 顶点 (−0.5,−0.5)(0.5,−0.5)(0.5,0.5)(−0.5,0.5) 线宽 2：正方形边长 16 像素，每条边是 16 × 2 的矩形（矩形线不出端点），4 条 = 128，
//     相邻两条在角上重叠 1 像素 ×4 → 124（闭合边 3→0 也要画；按条带只有 3 条边 = 96 − 2 = 94）
//   D 条带 16 位索引 {0, 1, 0xFFFF, 2, 3}、开图元重启，两条横线 y = −0.5 / +0.5（x −0.5..0.5）线宽 2：重启处断开，两条各 16 × 2 = 64；
//     顶点缓冲垫满 65536 个（其余在原点），把 0xFFFF 当顶点号（审计 #846 F-wline-restart）会多画 1→65535→2 两段斜线，不是 64
// 反证（旧代码只有 1 像素线）：A 16、B 16、C 不是 124
#import <Metal/Metal.h>
#include "../gal_abi.h"
#include "../gal_formats.h"
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
}
static void verts(const float *xyz, int n) {
    uint32_t vb = buf_of(xyz, n * 12); nxgal_vbuf v = {{vb, 0, n * 12, 0}, 12, 0}; nxgal_set_vertex_buffers(&v, 1);
    nxgal_vattr at = {0, 0, 0, F_R32G32B32Float}; nxgal_set_vertex_attribs(&at, 1);
}
static int count_red(void) {
    uint8_t px[32 * 32 * 4]; if (nxgal_tex_get_data(g_rt, 0, 0, px, sizeof px) != (int)sizeof px) return -1;
    int n = 0; for (int i = 0; i < 32 * 32; i++) n += px[4 * i] == 255; return n;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    if (nxgal_init(0)) return 2;
    char dir[1024]; snprintf(dir, sizeof dir, "%s", argv[0]); char *sl = strrchr(dir, '/'); if (sl) *sl = 0; else strcpy(dir, ".");
    char p[1100]; uint32_t lv = 0, lf = 0;
    snprintf(p, sizeof p, "%s/t_wline_in/vs.spv", dir); void *vs = slurp(p, &lv);
    snprintf(p, sizeof p, "%s/t_wline_in/fs.spv", dir); void *fs = slurp(p, &lf);
    if (!vs || !fs) { printf("  ✗ 读不到 %s/t_wline_in/*.spv（make -C graphics/metal 生成）\n", dir); return 1; }
    printf("· 宽线：条带 / 16 位索引列表（基顶点）/ 环，线宽 4 / 2 / 2，数像素；线宽 1 不展开（NXGAL_VPULL=%s）\n", getenv("NXGAL_VPULL") ? getenv("NXGAL_VPULL") : "未设");
    nxgal_shader sh[2] = {{vs, lv, 1}, {fs, lf, 5}};
    g_prog = nxgal_prog_create(sh, 2, NULL, 0, 0xf);
    int st = nxgal_prog_status(g_prog, 1); CHECK(st == 0, "建程序失败（状态 %d）：%s", st, nxgal_prog_last_error()); if (st) return 1;
    nxgal_tex_info ri = ti(32, 32, F_R8G8B8A8Unorm, 4); g_rt = nxgal_tex_create(&ri);
    static const float hl[6] = {-0.5f, 0, 0, 0.5f, 0, 0};
    setup(); verts(hl, 2); nxgal_set_topology(3); nxgal_set_line_params(4, 0); nxgal_draw(2, 1, 0, 0);
    int a = count_red(); CHECK(a == 64, "A 条带线宽 4：期望 64 像素，实得 %d", a);
    setup(); verts(hl, 2); nxgal_set_topology(3); nxgal_set_line_params(1, 0); nxgal_draw(2, 1, 0, 0);
    int a1 = count_red(); CHECK(a1 == 16, "A 条带线宽 1：期望 16 像素（不展开），实得 %d", a1);
    static const float vl[9] = {9, 9, 0, 0, -0.5f, 0, 0, 0.5f, 0};   // 垫一个顶点：基顶点 1
    uint16_t ix[2] = {1, 0}; uint32_t ib = buf_of(ix, 4);
    setup(); verts(vl, 3); nxgal_set_topology(1); nxgal_set_line_params(2, 0);
    nxgal_buf_range ir = {ib, 0, 4, 0}; nxgal_set_index_buffer(&ir, 1); nxgal_draw_indexed(2, 1, 0, 1, 0);
    int b = count_red(); CHECK(b == 32, "B 16 位索引列表线宽 2、基顶点 1：期望 32 像素，实得 %d", b);
    static const float sq[12] = {-0.5f, -0.5f, 0, 0.5f, -0.5f, 0, 0.5f, 0.5f, 0, -0.5f, 0.5f, 0};
    setup(); verts(sq, 4); nxgal_set_topology(2); nxgal_set_line_params(2, 0); nxgal_draw(4, 1, 0, 0);
    int c = count_red(); CHECK(c == 124, "C 环线宽 2：期望 124 像素（4 条边含闭合边、角上重叠 4），实得 %d", c);
    static const float two[12] = {-0.5f, -0.5f, 0, 0.5f, -0.5f, 0, -0.5f, 0.5f, 0, 0.5f, 0.5f, 0};
    float *big = calloc(65536 * 3, sizeof(float)); memcpy(big, two, sizeof two);
    uint16_t rx[5] = {0, 1, 0xFFFF, 2, 3}; uint32_t rb = buf_of(rx, 10);
    setup(); verts(big, 65536); free(big); nxgal_set_topology(3); nxgal_set_line_params(2, 0); nxgal_set_primitive_restart(1, 0xffff);
    nxgal_buf_range rr = {rb, 0, 10, 0}; nxgal_set_index_buffer(&rr, 1); nxgal_draw_indexed(5, 1, 0, 0, 0);
    int d = count_red(); CHECK(d == 64, "D 16 位索引条带开重启线宽 2：期望 64 像素（重启处断开），实得 %d", d);
    nxgal_set_primitive_restart(0, 0xffff);
    nxgal_set_line_params(1, 0);
    printf("%s：%d / %d 项通过\n", g_fail ? "失败" : "通过", g_checks - g_fail, g_checks);
    return g_fail != 0;
}
