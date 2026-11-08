// 绘制号（gl_DrawID，SPIR-V BuiltIn DrawIndex）端到端单测（图形接口盘点静默 1）：tests/t_drawid_*.spvasm → 运行时现翻 → 画 8×8 RGBA8 → 读回比手算期望。
// 只用 nxgal_* 公开接口（旧代码同样能编，供反证）。
// 背景：能力表报 SupportsIndirectParameters，Ryujinx 多绘制间接计数时着色器读内建绘制号；SPIRV-Cross 把它固定模拟成读 19 号缓冲槽（spirv_msl.cpp draw_id_buffer_index），
//   而我们 19 号是顶点缓冲 11——没人往那里写绘制号。
// 顶点着色器：绘制号 0 → 红、x 不动（左半屏 x ∈ [−1, 0]）；绘制号 1 → 绿、x 右移 1（右半屏）。
// 期望（手算，不跑被测实现）：
//   ① 普通绘制（绘制号恒 0，同 Vulkan 非多绘制）：左 4 列红、右 4 列保持清屏 0
//   ② 间接计数绘制 2 条（同一组 6 顶点参数）：左 4 列红、右 4 列绿
//   ③ 间接计数绘制，计数 1 / 上限 2：只有第 0 条 → 左红右 0
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
static uint32_t buf_of(const void *p, int n) { uint32_t b = nxgal_buf_create(n, 0); nxgal_buf_set_data(b, 0, p, n); return b; }

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    if (nxgal_init(0)) return 2;
    char dir[1024]; snprintf(dir, sizeof dir, "%s", argv[0]); char *sl = strrchr(dir, '/'); if (sl) *sl = 0; else strcpy(dir, ".");
    char p[1100]; uint32_t lv = 0, lf = 0;
    snprintf(p, sizeof p, "%s/t_drawid_in/vs.spv", dir); void *vs = slurp(p, &lv);
    snprintf(p, sizeof p, "%s/t_drawid_in/fs.spv", dir); void *fs = slurp(p, &lf);
    if (!vs || !fs) { printf("  ✗ 读不到 %s/t_drawid_in/*.spv（make -C graphics/metal 生成）\n", dir); return 1; }
    printf("· 绘制号：普通绘制恒 0（只左半红）；间接计数 2 条 → 左红右绿；计数 1 → 只左红\n");
    nxgal_shader sh[2] = {{vs, lv, 1}, {fs, lf, 5}};
    uint32_t prog = nxgal_prog_create(sh, 2, NULL, 0, 0xf);
    int st = nxgal_prog_status(prog, 1);
    CHECK(st == 0, "建程序失败（状态 %d）：%s", st, nxgal_prog_last_error());
    if (st) return 1;
    nxgal_tex_info rt = {8, 8, 1, 1, 1, 1, 1, 4, F_R8G8B8A8Unorm, 0, 1, {2, 3, 4, 5}}; uint32_t tex = nxgal_tex_create(&rt);
    static const float q[18] = {-1, -1, 0, 0, -1, 0, 0, 1, 0, -1, -1, 0, 0, 1, 0, -1, 1, 0};   // 左半屏两个三角
    uint32_t vb = buf_of(q, sizeof q);
    uint32_t prm[8] = {6, 1, 0, 0, 6, 1, 0, 0};   // 两条非索引间接参数（顶点数 / 实例数 / 首顶点 / 首实例），步长 16
    uint32_t ind = buf_of(prm, sizeof prm);
    const char *nm[3] = {"① 普通绘制", "② 间接计数 2 条", "③ 间接计数 计数 1 / 上限 2"};
    for (int k = 0; k < 3; k++) {
        nxgal_set_render_targets(&tex, 1, 0);
        nxgal_blend b = {0, {0, 0, 0, 0}, 1, 2, 1, 1, 2, 1}; for (int i = 0; i < 8; i++) nxgal_set_blend(i, &b);
        nxgal_depth_test dt = {0, 0, 8}; nxgal_set_depth_test(&dt);
        nxgal_stencil ss; memset(&ss, 0, sizeof ss); nxgal_set_stencil_test(&ss);
        nxgal_set_face_culling(0, 0x405); nxgal_set_front_face(0x901);
        nxgal_viewport vp = {0, 0, 8, 8, {0, 2, 4, 6}, 0, 1}; nxgal_set_viewports(&vp, 1);
        nxgal_rect full = {0, 0, 0xffff, 0xffff}; nxgal_set_scissors(&full, 1);
        float z[4] = {0, 0, 0, 0}; nxgal_clear_color(0, 0, 1, 0xf, z);
        nxgal_rect sc = {0, 0, 8, 8}; nxgal_set_scissors(&sc, 1);
        uint32_t m[8] = {0xf, 0xf, 0xf, 0xf, 0xf, 0xf, 0xf, 0xf}; nxgal_set_color_masks(m, 8);
        nxgal_set_program(prog);
        nxgal_vbuf v = {{vb, 0, (int32_t)sizeof q, 0}, 12, 0}; nxgal_set_vertex_buffers(&v, 1);
        nxgal_vattr at = {0, 0, 0, F_R32G32B32Float}; nxgal_set_vertex_attribs(&at, 1);
        nxgal_set_topology(4);
        if (k == 0) nxgal_draw(6, 1, 0, 0);
        else { uint32_t c = k == 1 ? 2 : 1; uint32_t cb = buf_of(&c, 4);
               nxgal_buf_range ir = {ind, 0, (int32_t)sizeof prm, 0}, pr = {cb, 0, 4, 0}; nxgal_draw_indirect_count(&ir, &pr, 2, 16, 0); }
        uint8_t px[8 * 8 * 4]; int rd = nxgal_tex_get_data(tex, 0, 0, px, sizeof px) == (int)sizeof px;
        int red = 0, green = 0, zero = 0;
        for (int y = 0; y < 8; y++) for (int x = 0; x < 8; x++) { const uint8_t *c = px + (y * 8 + x) * 4;
            int isr = c[0] == 255 && c[1] == 0 && c[2] == 0 && c[3] == 255, isg = c[0] == 0 && c[1] == 255 && c[2] == 0 && c[3] == 255, isz = !c[0] && !c[1] && !c[2] && !c[3];
            if (x < 4) red += isr; else if (k == 1) green += isg; else zero += isz; }
        CHECK(rd && red == 32, "%s：左 4 列期望 32 像素红，实得 %d（(0,0) = %u %u %u %u）", nm[k], red, px[0], px[1], px[2], px[3]);
        if (k == 1) CHECK(green == 32, "%s：右 4 列期望 32 像素绿，实得 %d（(7,0) = %u %u %u %u）", nm[k], green, px[28], px[29], px[30], px[31]);
        else CHECK(zero == 32, "%s：右 4 列期望保持清屏 0，实得 %d 像素为 0（(7,0) = %u %u %u %u）", nm[k], zero, px[28], px[29], px[30], px[31]);
    }
    printf("%s：%d / %d 项通过\n", g_fail ? "失败" : "通过", g_checks - g_fail, g_checks);
    return g_fail != 0;
}
