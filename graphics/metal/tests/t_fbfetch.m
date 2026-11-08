// 片元帧缓冲读取（gal_draw.m fbfetch_variant / gal_prog_fbfetch）单测：TextureBarrier 后本遍采样自己的颜色附件。
// 走真实翻译（10-21 画面·着色器线 gal_fbr.m 合入后：原先单测里手写的强符号与 MSL 程序删掉，程序改由手写 SPIR-V 建，翻译器自己证明、出变体）：
//   顶点 tests/t_fbr_vsp（out loc4 = ((x+w)/2, (w+y)/2, 0, w)）、第一次绘制片元 t_fbr_pat、第二次绘制片元 t_fbr_fsf（B = texture(A, loc4.xy / loc4.w)，集 2 绑定 0）。
// 两遍同一流程：① 变体还没编好（占住现编槽，翻译器返回 NULL）→ 照旧收遍；② 变体编好 → 不收遍。
// 期望按定义手算（GAL 视口高为正时 NDC y = −1 在顶行）：第一次绘制 A = 按像素中心的渐变 (x+0.5)/32、(y+0.5)/32、0.5、1（RGBA8 取整），B 清 0；TextureBarrier 后第二次绘制按屏幕坐标采样 A（最近点）写进 B
// → 两遍 B 都逐像素等于 A；渲染编码器 ① 2 个 ② 1 个；② 改读帧缓冲的绘制 +1。再加反例：视口没铺满附件 → 不取变体、照旧收遍；翻转视口 → 渲染器传 ydown = 0
#import <Metal/Metal.h>
#include "../gal_abi.h"
#include "../gal_internal.h"
#include <libgen.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

GAL_MTL4_ZONE_BEGIN
extern uint64_t g_fbfetch_draws;
NXGAL_API void nxgal_test_xc_hold_slots(int on);
const gal_prog *gal_prog_fbfetch(const gal_prog *pg, const uint8_t *bind, const uint8_t *slot, int n, int ydown);
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
static uint32_t prog(const char *vs, const char *fs) {
    uint32_t vl, fl; uint8_t *v = load(vs, &vl), *f = load(fs, &fl);
    nxgal_shader sh[2] = {{v, vl, 1}, {f, fl, 5}};
    uint32_t id = nxgal_prog_create(sh, 2, NULL, 0, 0xff); free(v); free(f);
    if (nxgal_prog_status(id, 1) != 0) { printf("程序 %s + %s 建不出：%s\n", vs, fs, nxgal_prog_last_error()); exit(2); }
    return id;
}
enum { RGBA8 = 36 };
static nxgal_tex_info ti(int w, int h, int fmt, int bpp) { nxgal_tex_info i = {w, h, 1, 1, 1, 1, 1, bpp, fmt, 0, 1, {2, 3, 4, 5}}; return i; }
static uint32_t P_pat, P_samp, P_flip;

static void set_ubo(void) { float c[4] = {1, 1, 1, 1}; uint32_t u = nxgal_buf_create(16, 0); nxgal_buf_set_data(u, 0, c, 16); nxgal_buf_assign a0 = {0, {u, 0, 16, 0}}; nxgal_set_uniform_buffers(&a0, 1); }
static void set_quad(void) {
    float v[12] = {-1, -1, 0.5f, 1, -1, 0.5f, 1, 1, 0.5f, -1, 1, 0.5f};
    uint32_t b = nxgal_buf_create(48, 0); nxgal_buf_set_data(b, 0, v, 48);
    nxgal_vbuf vb = {{b, 0, 48, 0}, 12, 0}; nxgal_set_vertex_buffers(&vb, 1);
    nxgal_vattr at = {0, 0, 0, 33}; nxgal_set_vertex_attribs(&at, 1); nxgal_set_topology(7 /* Quads */);
}
static void base_state(float vx, float vw, int flip) {
    nxgal_blend b = {0, {0, 0, 0, 0}, 1, 2, 1, 1, 2, 1}; for (int i = 0; i < 8; i++) nxgal_set_blend(i, &b);
    nxgal_depth_test d = {0, 0, 8}; nxgal_set_depth_test(&d);
    nxgal_stencil s; memset(&s, 0, sizeof s); nxgal_set_stencil_test(&s);
    nxgal_set_face_culling(0, 0x405); nxgal_set_front_face(0x901);
    nxgal_viewport vp = {vx, flip ? 32 : 0, vw, flip ? -32 : 32, {0, 2, 4, 6}, 0, 1}; nxgal_set_viewports(&vp, 1);
    nxgal_rect sc = {0, 0, 32, 32}; nxgal_set_scissors(&sc, 1);
    uint32_t m[8] = {0xf, 0xf, 0xf, 0xf, 0xf, 0xf, 0xf, 0xf}; nxgal_set_color_masks(m, 8);
}
static int read32(uint32_t tex, uint8_t *px) { return nxgal_tex_get_data(tex, 0, 0, px, 32 * 32 * 4) == 32 * 32 * 4; }
static uint8_t u8(double v) { return (uint8_t)lround(v * 255.0); }

// 一遍：返回渲染编码器数；A、B 读回到 a、b
// ai：A 的贴图描述（NULL = 32×32 RGBA8 单级）；samp：第二次绘制的采样程序
static uint64_t run_a(const nxgal_tex_info *ai, uint32_t samp, uint32_t smp, float vx, float vw, int flip, uint8_t *a, uint8_t *b, uint64_t *fetched) {
    nxgal_tex_info ci = ti(32, 32, RGBA8, 4);
    uint32_t A = nxgal_tex_create(ai ? ai : &ci), B = nxgal_tex_create(&ci);
    uint32_t ab[2] = {A, B}; nxgal_set_render_targets(ab, 2, 0);
    base_state(vx, vw, flip); set_ubo(); set_quad();
    uint64_t e0 = g_gp_n[GP_RENC], f0 = g_fbfetch_draws;
    nxgal_set_program(P_pat); nxgal_draw(4, 1, 0, 0);
    nxgal_barrier(2);   // TextureBarrier
    uint32_t m[8] = {0, 0xf, 0xf, 0xf, 0xf, 0xf, 0xf, 0xf}; nxgal_set_color_masks(m, 8);
    nxgal_set_texture_sampler(5, 0, A, smp);
    nxgal_set_program(samp); nxgal_draw(4, 1, 0, 0);
    uint64_t enc = g_gp_n[GP_RENC] - e0; *fetched = g_fbfetch_draws - f0;
    read32(A, a); read32(B, b);
    nxgal_set_texture_sampler(5, 0, 0, 0);
    nxgal_tex_release(A); nxgal_tex_release(B);
    return enc;
}
static uint64_t run(uint32_t samp, uint32_t smp, float vx, float vw, int flip, uint8_t *a, uint8_t *b, uint64_t *fetched) { return run_a(NULL, samp, smp, vx, vw, flip, a, b, fetched); }
// 直接问翻译器（当前目标组 = 两张 32×32 RGBA8）
static const gal_prog *ask(uint32_t pid, int ydown) {
    nxgal_tex_info ci = ti(32, 32, RGBA8, 4);
    uint32_t A = nxgal_tex_create(&ci), B = nxgal_tex_create(&ci); uint32_t ab[2] = {A, B}; nxgal_set_render_targets(ab, 2, 0);
    uint8_t bind = 0, slot = 0; const gal_prog *v = gal_prog_fbfetch(gal_prog_get(pid), &bind, &slot, 1, ydown);
    nxgal_tex_release(A); nxgal_tex_release(B);
    return v;
}
static const gal_prog *wait_variant(uint32_t pid, int ydown) {
    for (int i = 0; i < 1000; i++) { const gal_prog *v = ask(pid, ydown); if (v) return v; usleep(20000); }
    return NULL;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    (void)argc; char exe[1024]; snprintf(exe, sizeof exe, "%s", argv[0]); snprintf(g_dir, sizeof g_dir, "%s/t_fbr_in", dirname(exe));
    if (nxgal_init(0)) return 2;
    P_pat = prog("vsp", "pat"); P_samp = prog("vsp", "fsf"); P_flip = prog("vs", "fsf");
    nxgal_sampler_info si = {0, 0, 0, 2, 2, 2, 0, 8, {0, 0, 0, 0}, 0, 1000, 0, 1};   // 最近点、夹边
    uint32_t smp = nxgal_sampler_create(&si);
    static uint8_t a1[4096], b1[4096], a2[4096], b2[4096], a3[4096], b3[4096];

    printf("· TextureBarrier 后本遍采样自己的颜色附件：变体没编好收遍（2 个渲染编码器）；编好改读帧缓冲不收遍（1 个）；两遍 B 都逐像素等于 A，A = 手算渐变\n");
    uint64_t f1, f2, f3;
    nxgal_test_xc_hold_slots(1); uint64_t e1 = run(P_samp, smp, 0, 32, 0, a1, b1, &f1); nxgal_test_xc_hold_slots(0);
    wait_variant(P_samp, 1);
    uint64_t e2 = run(P_samp, smp, 0, 32, 0, a2, b2, &f2);
    // 原「期望传给翻译器 ydown = 1」：翻译器对 (w+y) 程序只在 ydown = 1 给变体，正向视口下这次绘制改读了帧缓冲 ⇔ 渲染器传的是 ydown = 1
    CHECK(f2 == 1 && ask(P_samp, 1) != NULL && ask(P_samp, 0) == NULL, "正向视口：期望渲染器传 ydown = 1（(w+y) 程序只在 ydown = 1 给变体，且这次改读了 1 次），实得改读 %llu 次", (unsigned long long)f2);
    int pat_bad = 0; for (int y = 0; y < 32; y++) for (int x = 0; x < 32; x++) { const uint8_t *p = a2 + (y * 32 + x) * 4; int ex = u8((x + 0.5) / 32), ey = u8((y + 0.5) / 32);
        if (abs(p[0] - ex) > 1 || abs(p[1] - ey) > 1 || abs(p[2] - 128) > 1 || p[3] != 255) pat_bad++; }
    CHECK(pat_bad == 0, "A 期望像素中心渐变（±1），实得 %d 像素不符", pat_bad);
    CHECK(!memcmp(a1, b1, 4096), "收遍：B 期望逐像素等于 A");
    CHECK(!memcmp(a2, b2, 4096), "改读帧缓冲：B 期望逐像素等于 A");
    CHECK(!memcmp(b1, b2, 4096), "两遍 B 期望逐字节相同");
    CHECK(e1 == 2 && f1 == 0, "收遍：期望渲染编码器 2 个 / 改读 0 次，实得 %llu / %llu", (unsigned long long)e1, (unsigned long long)f1);
    CHECK(e2 == 1 && f2 == 1, "改读帧缓冲：期望渲染编码器 1 个 / 改读 1 次，实得 %llu / %llu", (unsigned long long)e2, (unsigned long long)f2);

    printf("· 反例：视口只铺左半（x 0、宽 16）→ 不取变体、照旧收遍（2 个渲染编码器 / 改读 0 次）\n");
    uint64_t e3 = run(P_samp, smp, 0, 16, 0, a3, b3, &f3);
    CHECK(e3 == 2 && f3 == 0, "视口没铺满：期望渲染编码器 2 个 / 改读 0 次，实得 %llu / %llu", (unsigned long long)e3, (unsigned long long)f3);
    printf("· 翻转视口（y 32、高 −32）→ 渲染器传 ydown = 0：(w+y) 程序翻译器不给变体 → 照旧收遍；(w−y) 程序拿到变体\n");
    uint64_t f4, f5; uint64_t e4 = run(P_samp, smp, 0, 32, 1, a3, b3, &f4);
    wait_variant(P_flip, 0);
    run(P_flip, smp, 0, 32, 1, a3, b3, &f5);
    // 原「期望传 ydown = 0」：(w−y) 程序只在 ydown = 0 给变体，翻转视口下它改读了帧缓冲 ⇔ 渲染器传的是 ydown = 0
    CHECK(f5 == 1 && ask(P_flip, 0) != NULL && ask(P_flip, 1) == NULL, "翻转视口：期望渲染器传 ydown = 0（(w−y) 程序只在 ydown = 0 给变体，且这次改读了 1 次），实得改读 %llu 次", (unsigned long long)f5);
    CHECK(e4 == 2 && f4 == 0, "翻转视口：期望渲染编码器 2 个 / 改读 0 次，实得 %llu / %llu", (unsigned long long)e4, (unsigned long long)f4);

    // 实际采样的视图 / 采样器 LOD（画面·着色器线 10-21 指出）：③ A 带通道重排（红蓝互换，采样走重排视图）→ 不取变体、照旧收遍；
    // ④ A 2 级 mip、采样器最小 LOD = 1（采的是 1 级）→ 照旧收遍；⑤ A 2 级 mip、最小 LOD = 0、偏移 0 → 照常改读帧缓冲（正对照：多级 mip 本身不拦）
    // 三项都用 P_samp：它 ydown = 1 的变体上面已编好（翻译器按程序 + 映射缓存），③④ 被拦只能是渲染器的运行时判据
    printf("· 反例：采样视图有通道重排、或多级 mip 且采样器最小 LOD > 0 → 不取变体照旧收遍；多级 mip 但最小 LOD = 0 照常改读帧缓冲\n");
    {
        nxgal_tex_info sw = ti(32, 32, RGBA8, 4); sw.swz[0] = 4; sw.swz[2] = 2;
        nxgal_tex_info mip = ti(32, 32, RGBA8, 4); mip.levels = 2;
        nxgal_sampler_info s1 = si; s1.min_lod = 1; s1.max_lod = 1000; uint32_t smp1 = nxgal_sampler_create(&s1);
        uint64_t f5, f6, f7;
        uint64_t e5 = run_a(&sw, P_samp, smp, 0, 32, 0, a3, b3, &f5);
        CHECK(e5 == 2 && f5 == 0, "③ 采样视图有通道重排：期望渲染编码器 2 个 / 改读 0 次，实得 %llu / %llu", (unsigned long long)e5, (unsigned long long)f5);
        uint64_t e6 = run_a(&mip, P_samp, smp1, 0, 32, 0, a3, b3, &f6);
        CHECK(e6 == 2 && f6 == 0, "④ 2 级 mip、最小 LOD 1：期望渲染编码器 2 个 / 改读 0 次，实得 %llu / %llu", (unsigned long long)e6, (unsigned long long)f6);
        uint64_t e7 = run_a(&mip, P_samp, smp, 0, 32, 0, a3, b3, &f7);
        CHECK(e7 == 1 && f7 == 1, "⑤ 2 级 mip、最小 LOD 0：期望渲染编码器 1 个 / 改读 1 次，实得 %llu / %llu", (unsigned long long)e7, (unsigned long long)f7);
        CHECK(!memcmp(a3, b3, 4096), "⑤ B 期望逐像素等于 A 的 0 级");
    }

    nxgal_shutdown();
    printf("%s：%d / %d 项通过\n", g_fail ? "失败" : "通过", g_checks - g_fail, g_checks);
    return g_fail ? 1 : 0;
}
GAL_MTL4_ZONE_END
