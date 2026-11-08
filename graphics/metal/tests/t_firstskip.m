// 首遇不阻塞单测（gal_prog.m gal_prog_get_draw，10-21 首局根治 A 层）：程序首遇现编没编完时，这次绘制跳过、不等，计数 +1；编完后下一次照常画。
// 程序用手写 SPIR-V（tests/t_fbr_vsp + t_fbr_pat，与 t_fbfetch 同一份）：顶点铺满、片元出像素中心渐变 (x+0.5)/32、(y+0.5)/32、0.5、1。
// 确定性：新的空着色器持久缓存目录（必须现编）+ nxgal_test_xc_hold_slots(1) 占住现编槽位 + NXGAL_FIRST_BOOST=0（作业拿不到槽、首遇加速不开）→ 第一次绘制时作业一定没编完。
// 期望（手算）：① 占住时画一次：跳过计数 +1、目标保持清屏值 0、绘制调用当场返回（< 50 ms）；② 放开、等程序编完后再画：计数不变、目标 = 渐变（±1）。
// 反证：不设 NXGAL_FIRST_SKIP（缺省阻塞）时 ① 会一直等槽位——本单测不跑那条（会卡死），由「① 当场返回」这一项代证。
#import <Metal/Metal.h>
#include "../gal_abi.h"
#include "../gal_internal.h"
#include <libgen.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <mach/mach_time.h>

GAL_MTL4_ZONE_BEGIN
extern uint64_t g_first_skips;
NXGAL_API void nxgal_test_xc_hold_slots(int on);
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
enum { RGBA8 = 36 };
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
static uint8_t u8(double v) { return (uint8_t)lround(v * 255.0); }
static double ms_since(uint64_t t0) { mach_timebase_info_data_t tb; mach_timebase_info(&tb); return (double)(mach_absolute_time() - t0) * tb.numer / tb.denom / 1e6; }

// 画一次铺满四边形到新目标 A（先清 0），读回 A；返回绘制调用本身的耗时 ms
static double draw_once(uint32_t prog, uint8_t *a) {
    nxgal_tex_info ci = ti(32, 32, RGBA8, 4); uint32_t A = nxgal_tex_create(&ci);
    nxgal_set_render_targets(&A, 1, 0);
    float z[4] = {0, 0, 0, 0}; nxgal_clear_color(0, 0, 1, 0xf, z);
    base_state(); set_ubo(); set_quad(); nxgal_set_program(prog);
    uint64_t t0 = mach_absolute_time(); nxgal_draw(4, 1, 0, 0); double ms = ms_since(t0);
    nxgal_tex_get_data(A, 0, 0, a, 32 * 32 * 4); nxgal_tex_release(A);
    return ms;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    (void)argc; char exe[1024]; snprintf(exe, sizeof exe, "%s", argv[0]); snprintf(g_dir, sizeof g_dir, "%s/t_fbr_in", dirname(exe));
    char cd[] = "/tmp/t_firstskip.XXXXXX"; if (!mkdtemp(cd)) return 2; setenv("NXGAL_SHADER_CACHE_DIR", cd, 1);   // 新空缓存：必须现编
    setenv("NXGAL_BOUNDS_COUNT", "0", 1); setenv("NXGAL_FIRST_BOOST", "0", 1);   // 不加速：占住槽位期间作业确定编不了
    setenv("NXGAL_FIRST_SKIP", "1", 1);   // 渲染器缺省阻塞，产品局由 RenderLoop.cs 打开
    if (nxgal_init(0)) return 2;
    static uint8_t a1[4096], a2[4096];

    printf("· 首遇作业没编完（占住现编槽位）：这次绘制跳过、当场返回、计数 +1；编完后再画：照常画出渐变\n");
    nxgal_test_xc_hold_slots(1);
    uint32_t vl, fl; uint8_t *v = load("vsp", &vl), *f = load("pat", &fl);
    nxgal_shader sh[2] = {{v, vl, 1}, {f, fl, 5}};
    uint32_t P = nxgal_prog_create(sh, 2, NULL, 0, 0xff); free(v); free(f);
    CHECK(P && nxgal_prog_status(P, 0) == 2, "建程序后状态期望 2（编译中），实得 %d", P ? nxgal_prog_status(P, 0) : -1);
    uint64_t s0 = g_first_skips;
    double ms1 = draw_once(P, a1);
    int nz1 = 0; for (int i = 0; i < 4096; i++) nz1 += a1[i] != 0;
    CHECK(g_first_skips - s0 == 1, "① 跳过计数期望 +1，实得 +%llu", (unsigned long long)(g_first_skips - s0));
    CHECK(nz1 == 0, "① 目标期望保持清屏值 0（没画），实得 %d 字节非 0", nz1);
    CHECK(ms1 < 50, "① 绘制调用期望当场返回（< 50 ms），实得 %.1f ms", ms1);
    nxgal_test_xc_hold_slots(0);
    int st = 2; for (int i = 0; i < 500 && (st = nxgal_prog_status(P, 0)) == 2; i++) usleep(10000);
    CHECK(st == 0, "放开后程序期望编完（状态 0），实得 %d", st);
    uint64_t s1 = g_first_skips;
    draw_once(P, a2);
    int bad = 0; for (int y = 0; y < 32; y++) for (int x = 0; x < 32; x++) { const uint8_t *p = a2 + (y * 32 + x) * 4; int ex = u8((x + 0.5) / 32), ey = u8((y + 0.5) / 32);
        if (abs(p[0] - ex) > 1 || abs(p[1] - ey) > 1 || abs(p[2] - 128) > 1 || p[3] != 255) bad++; }
    CHECK(g_first_skips == s1, "② 编完后跳过计数期望不变，实得 +%llu", (unsigned long long)(g_first_skips - s1));
    CHECK(bad == 0, "② 期望画出像素中心渐变（±1），实得 %d 像素不符", bad);

    nxgal_shutdown();
    char rm[256]; snprintf(rm, sizeof rm, "rm -rf '%s'", cd); system(rm);
    printf("%s：%d / %d 项通过\n", g_fail ? "失败" : "通过", g_checks - g_fail, g_checks);
    return g_fail ? 1 : 0;
}
GAL_MTL4_ZONE_END
