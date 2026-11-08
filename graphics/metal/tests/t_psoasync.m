// 管线异步现建单测（gal_state.m pso_build + gal_core.m gal_new_render_pso_async，10-21 首局根治 B，安全网）：基础管线归档没命中时不在绘制线程上等编译，
//   这次绘制跳过、计数 +1；编完后下一次照常画。程序用手写 SPIR-V（tests/t_fbr_vsp + t_fbr_pat）：顶点铺满、片元出像素中心渐变 (x+0.5)/32、(y+0.5)/32、0.5、1。
// 确定性：程序先等编完（排除首遇现编那条跳过）；没有归档 → 第一次绘制必然起异步任务、当场返回空（任务在这次调用里才起，不可能已编完）。
// 期望（手算）：① 第一次画：跳过 +1、目标保持清屏值 0（这两条就证明调用没等编译：等了就会画出来）；② 等异步现建在编条数归 0（nxgal_pso_inflight，按事件、不限墙钟，
//   300 秒只是防挂死的安全上限）后再画一次：不再跳过、目标 = 渐变（±1），现建计 1 条（取用时计）；
//   10-25：原先按墙钟判（① < 50 ms、② 反复画 ≤ 5 秒），整机负载 30–50 时后台编不完 5 秒就判「现建 0 条」，在列车里误伤别人的批次
//   对照 --sync（NXGAL_PSO_ASYNC=0）：第一次就画出渐变、跳过 0、现建 1 条。
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
    int sync = argc > 1 && !strcmp(argv[1], "--sync");
    char exe[1024]; snprintf(exe, sizeof exe, "%s", argv[0]); snprintf(g_dir, sizeof g_dir, "%s/t_fbr_in", dirname(exe));
    char cd[] = "/tmp/t_psoasync.XXXXXX"; if (!mkdtemp(cd)) return 2; setenv("NXGAL_SHADER_CACHE_DIR", cd, 1);
    setenv("NXGAL_BOUNDS_COUNT", "0", 1); setenv("NXGAL_PSO_ASYNC", sync ? "0" : "1", 1);   // 渲染器缺省同步，产品局由 RenderLoop.cs 打开
    if (nxgal_init(0)) return 2;
    // 同产品顺序先预建内部管线 / 等辅助库（RenderLoop.cs NxProgram.WarmInternal）：四边形拓扑第一次画要等索引转换辅助库，冷 Metal 缓存下几百 ms，
    //   不预热会算进 ①「当场返回」（10-21 合批门禁 764 ms 红；本机重跑系统 Metal 缓存命中 0 ms 掩盖）
    nxgal_warm_internal();
    static uint8_t a1[4096], a2[4096];
    printf("· 基础管线归档没命中（%s）：第一次画%s\n", sync ? "对照：同步" : "异步", sync ? "就画出" : "跳过、当场返回；编完后画出渐变");
    uint32_t vl, fl; uint8_t *v = load("vsp", &vl), *f = load("pat", &fl);
    nxgal_shader sh[2] = {{v, vl, 1}, {f, fl, 5}};
    uint32_t P = nxgal_prog_create(sh, 2, NULL, 0, 0xff); free(v); free(f);
    int st = 2; for (int i = 0; i < 500 && P && (st = nxgal_prog_status(P, 0)) == 2; i++) usleep(10000);
    CHECK(P && st == 0, "程序没编完（状态 %d）", st);
    uint64_t c0[4], c1[4]; nxgal_pso_cache_stats(c0);
    uint64_t s0 = g_first_skips; double ms1 = draw_once(P, a1);
    int nz1 = 0; for (int i = 0; i < 4096; i++) nz1 += a1[i] != 0;
    if (sync) CHECK(g_first_skips == s0 && nz1 > 0, "对照：第一次期望画出（跳过 0），实得跳过 +%llu、非 0 字节 %d", (unsigned long long)(g_first_skips - s0), nz1);
    else {
        CHECK(g_first_skips - s0 == 1, "① 跳过计数期望 +1，实得 +%llu", (unsigned long long)(g_first_skips - s0));
        CHECK(nz1 == 0, "① 目标期望保持清屏值 0，实得 %d 字节非 0", nz1);
        printf("  ① 绘制调用 %.1f ms（只打印，不判：负载高时调用本身也慢，没等编译由上两条证明）\n", ms1);
    }
    int n = 0;
    if (!sync) { uint64_t tw = mach_absolute_time(); while (nxgal_pso_inflight() > 0 && ms_since(tw) < 300000) usleep(10000);
        CHECK(nxgal_pso_inflight() == 0, "② 异步现建 300 秒还没编完（在编 %d 条）", nxgal_pso_inflight());
        printf("  ② 等编完 %.0f ms\n", ms_since(tw)); }
    uint64_t s1 = g_first_skips; draw_once(P, a2); n++;
    if (!sync) CHECK(g_first_skips == s1, "② 编完后再画期望不再跳过，实得跳过 +%llu", (unsigned long long)(g_first_skips - s1));
    int bad = 0; for (int y = 0; y < 32; y++) for (int x = 0; x < 32; x++) { const uint8_t *p = a2 + (y * 32 + x) * 4; int ex = u8((x + 0.5) / 32), ey = u8((y + 0.5) / 32);
        if (abs(p[0] - ex) > 1 || abs(p[1] - ey) > 1 || abs(p[2] - 128) > 1 || p[3] != 255) bad++; }
    CHECK(bad == 0, "② 期望画出像素中心渐变（±1），实得 %d 像素不符（画了 %d 次）", bad, n);
    nxgal_pso_cache_stats(c1);
    CHECK(c1[1] - c0[1] == 1, "现建期望 1 条，实得 %llu 条", (unsigned long long)(c1[1] - c0[1]));
    nxgal_shutdown();
    char rm[256]; snprintf(rm, sizeof rm, "rm -rf '%s'", cd); system(rm);
    printf("%s：%d / %d 项通过\n", g_fail ? "失败" : "通过", g_checks - g_fail, g_checks);
    return g_fail ? 1 : 0;
}
GAL_MTL4_ZONE_END
