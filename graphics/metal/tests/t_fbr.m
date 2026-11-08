// 片元帧缓冲读取的翻译器侧（gal_fbr.m：证明 + 变体）单测：手写 SPIR-V（tests/t_fbr_*.spvasm，Makefile 编进可执行文件旁的 t_fbr_in/）走真实翻译。
// 只用公开接口 + gal_prog_fbfetch / gal_prog_get（main 上都有：main 上 gal_prog_fbfetch 是弱缺省恒 NULL）——同一份测试对 main 的源码编，正例必红（旧代码反证）。
// 流程同 t_fbfetch：第一次绘制写 A（槽 0）= 像素中心渐变、B（槽 1）= 0；TextureBarrier；第二次绘制在 locK 推出的屏幕坐标处采样 A（线性过滤）写 B。
// 期望按定义手算：两种朝向下采样坐标都是当前像素中心 → B 逐像素等于 A；变体没编好时（占住现编槽）照旧拆遍（渲染编码器 2 个），
// 编好后改读帧缓冲不拆遍（1 个），两遍 B 逐字节相同。反例逐个只差一处（坐标没除 w / x 用 (w−x) / y 符号与 ydown 不配 / 采样的是别的贴图 / 缩放位为 1），翻译器返回 NULL
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
// 渲染器侧接口（gal_draw.m 声明的弱缺省 / gal_fbr.m 的强定义）
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
static uint32_t g_ubo;
// 集 0 绑定 0：vec4 + ivec4，ivec4.z 的位 0 = 缩放因子的位（同 Ryujinx s2a_flags.z）
static void set_ubo(int flag) {
    uint32_t c[8] = {0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u, 0, 0, (uint32_t)flag, 0};
    if (!g_ubo) g_ubo = nxgal_buf_create(32, 0);
    nxgal_buf_set_data(g_ubo, 0, c, 32); nxgal_buf_assign a0 = {0, {g_ubo, 0, 32, 0}}; nxgal_set_uniform_buffers(&a0, 1);
}
static void set_quad(void) {
    float v[12] = {-1, -1, 0.5f, 1, -1, 0.5f, 1, 1, 0.5f, -1, 1, 0.5f};
    uint32_t b = nxgal_buf_create(48, 0); nxgal_buf_set_data(b, 0, v, 48);
    nxgal_vbuf vb = {{b, 0, 48, 0}, 12, 0}; nxgal_set_vertex_buffers(&vb, 1);
    nxgal_vattr at = {0, 0, 0, 33}; nxgal_set_vertex_attribs(&at, 1); nxgal_set_topology(7);
}
static void base_state(int flip) {
    nxgal_blend b = {0, {0, 0, 0, 0}, 1, 2, 1, 1, 2, 1}; for (int i = 0; i < 8; i++) nxgal_set_blend(i, &b);
    nxgal_depth_test d = {0, 0, 8}; nxgal_set_depth_test(&d);
    nxgal_stencil s; memset(&s, 0, sizeof s); nxgal_set_stencil_test(&s);
    nxgal_set_face_culling(0, 0x405); nxgal_set_front_face(0x901);
    nxgal_viewport vp = {0, flip ? 32 : 0, 32, flip ? -32 : 32, {0, 2, 4, 6}, 0, 1}; nxgal_set_viewports(&vp, 1);
    nxgal_rect sc = {0, 0, 32, 32}; nxgal_set_scissors(&sc, 1);
    uint32_t m[8] = {0xf, 0xf, 0xf, 0xf, 0xf, 0xf, 0xf, 0xf}; nxgal_set_color_masks(m, 8);
}
static uint32_t g_smp, g_pat;
// 一遍：返回渲染编码器数；A、B 读回到 a、b；*fetched = 改读帧缓冲的绘制数
static uint64_t run(uint32_t samp, int bind, int flip, int flag, uint8_t *a, uint8_t *b, uint64_t *fetched) {
    nxgal_tex_info ci = ti(32, 32, RGBA8, 4);
    uint32_t A = nxgal_tex_create(&ci), B = nxgal_tex_create(&ci);
    uint32_t ab[2] = {A, B}; nxgal_set_render_targets(ab, 2, 0);
    base_state(flip); set_ubo(flag); set_quad();
    uint64_t e0 = g_gp_n[GP_RENC], f0 = g_fbfetch_draws;
    nxgal_set_program(g_pat); nxgal_draw(4, 1, 0, 0);
    nxgal_barrier(2);
    uint32_t m[8] = {0, 0xf, 0xf, 0xf, 0xf, 0xf, 0xf, 0xf}; nxgal_set_color_masks(m, 8);
    nxgal_set_texture_sampler(5, bind, A, g_smp);
    nxgal_set_program(samp); nxgal_draw(4, 1, 0, 0);
    uint64_t enc = g_gp_n[GP_RENC] - e0; *fetched = g_fbfetch_draws - f0;
    if (a) nxgal_tex_get_data(A, 0, 0, a, 4096);
    if (b) nxgal_tex_get_data(B, 0, 0, b, 4096);
    nxgal_set_texture_sampler(5, bind, 0, 0);
    nxgal_tex_release(A); nxgal_tex_release(B);
    return enc;
}
// 直接问翻译器（渲染器在 TextureBarrier 命中时就是这样调的）：当前目标组 = 两张 32×32 RGBA8，常量缓冲位 = flag
static const gal_prog *ask(uint32_t pid, uint8_t bind, uint8_t slot, int ydown, int flag) {
    nxgal_tex_info ci = ti(32, 32, RGBA8, 4);
    uint32_t A = nxgal_tex_create(&ci), B = nxgal_tex_create(&ci); uint32_t ab[2] = {A, B}; nxgal_set_render_targets(ab, 2, 0); set_ubo(flag);
    const gal_prog *v = gal_prog_fbfetch(gal_prog_get(pid), &bind, &slot, 1, ydown);
    nxgal_tex_release(A); nxgal_tex_release(B);
    return v;
}
// 等变体编好（异步现编）：最多 20 秒
static const gal_prog *wait_variant(uint32_t pid, uint8_t bind, uint8_t slot, int ydown) {
    for (int i = 0; i < 1000; i++) { const gal_prog *v = ask(pid, bind, slot, ydown, 0); if (v) return v; usleep(20000); }
    return NULL;
}
static uint8_t u8(double v) { return (uint8_t)lround(v * 255.0); }
static int pat_bad(const uint8_t *a) {
    int bad = 0;
    for (int y = 0; y < 32; y++) for (int x = 0; x < 32; x++) {
        const uint8_t *p = a + (y * 32 + x) * 4; int ex = u8((x + 0.5) / 32), ey = u8((y + 0.5) / 32);
        if (abs(p[0] - ex) > 1 || abs(p[1] - ey) > 1 || abs(p[2] - 128) > 1 || p[3] != 255) bad++;
    }
    return bad;
}
static int diff_px(const uint8_t *x, const uint8_t *y) { int n = 0; for (int i = 0; i < 1024; i++) n += memcmp(x + 4 * i, y + 4 * i, 4) != 0; return n; }

// 正例：先占住现编槽（变体作业排着）→ 两种朝向各绘一遍，照旧拆遍；放开、等变体编好 → 再各绘一遍，改读帧缓冲不拆遍；每遍 B 都逐像素等于 A。
// 两个程序的片元同一支，改写后的片元也同一支（同键共用一个作业）：所以两遍拆遍都要在放开之前绘
typedef struct { const char *name; uint32_t samp; int flip; uint8_t a[4096], b[4096]; uint64_t enc, fetched; } pcase;
static void positive_split(pcase *c) { c->enc = run(c->samp, 128, c->flip, 0, c->a, c->b, &c->fetched); }
static void positive_fetch(pcase *c) {
    static uint8_t a2[4096], b2[4096]; uint64_t f2;
    int ydown = !c->flip;
    const gal_prog *v = wait_variant(c->samp, 128, 0, ydown);
    CHECK(v != NULL, "%s：期望 20 秒内拿到变体（ydown = %d），实得 NULL", c->name, ydown);
    uint64_t e2 = run(c->samp, 128, c->flip, 0, a2, b2, &f2);
    CHECK(c->enc == 2 && c->fetched == 0, "%s 变体未编好：期望拆遍（渲染编码器 2 个 / 改读 0 次），实得 %llu / %llu", c->name, (unsigned long long)c->enc, (unsigned long long)c->fetched);
    CHECK(e2 == 1 && f2 == 1, "%s 变体编好：期望不拆遍（渲染编码器 1 个 / 改读 1 次），实得 %llu / %llu", c->name, (unsigned long long)e2, (unsigned long long)f2);
    int pb = pat_bad(c->a);
    CHECK(pb == 0, "%s：A 期望像素中心渐变（±1），实得 %d 像素不符", c->name, pb);
    int d1 = diff_px(c->a, c->b), d2 = diff_px(a2, b2), d3 = diff_px(c->b, b2);
    CHECK(d1 == 0, "%s 拆遍：B 期望逐像素等于 A，实得 %d 像素不同", c->name, d1);
    CHECK(d2 == 0, "%s 改读帧缓冲：B 期望逐像素等于 A，实得 %d 像素不同", c->name, d2);
    CHECK(d3 == 0, "%s：两遍 B 期望逐字节相同，实得 %d 像素不同", c->name, d3);
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    (void)argc; char exe[1024]; snprintf(exe, sizeof exe, "%s", argv[0]); snprintf(g_dir, sizeof g_dir, "%s/t_fbr_in", dirname(exe));
    if (nxgal_init(0)) return 2;
    // 线性过滤、夹边（坐标是像素中心时线性过滤也只取到本像素：拆遍结果 = A）
    nxgal_sampler_info si = {2, 2, 0, 2, 2, 2, 0, 8, {0, 0, 0, 0}, 0, 1000, 0, 1};
    g_smp = nxgal_sampler_create(&si);
    g_pat = prog("vsp", "pat");
    uint32_t P_m = prog("vs", "fs"), P_p = prog("vsp", "fs"), P_x = prog("vsx", "fs"), P_n = prog("vsp", "fsn"), P_o = prog("vsp", "fso");

    printf("· 正例 ①：Ryujinx 形态顶点 (w−y)·0.5 配翻转视口（ydown = 0），片元带缩放因子 + NaN 兜底 + 取尺寸，线性过滤\n");
    printf("· 正例 ②：SSA 写法顶点 (w+y)·0.5 配正向视口（ydown = 1），同一片元\n");
    static pcase C1 = {"(w−y) / 翻转视口", 0, 1, {0}, {0}, 0, 0}, C2 = {"(w+y) / 正向视口", 0, 0, {0}, {0}, 0, 0};
    C1.samp = P_m; C2.samp = P_p;
    nxgal_test_xc_hold_slots(1); positive_split(&C1); positive_split(&C2); nxgal_test_xc_hold_slots(0);
    positive_fetch(&C1); positive_fetch(&C2);

    printf("· 反例：只差一处，翻译器返回 NULL（各自的正向对照给变体）\n");
    CHECK(ask(P_m, 128, 0, 0, 0) != NULL, "对照：(w−y) 配 ydown = 0 期望给变体");
    CHECK(ask(P_m, 128, 0, 1, 0) == NULL, "y 符号与 ydown 不配：(w−y) 配 ydown = 1 期望 NULL");
    CHECK(ask(P_p, 128, 0, 0, 0) == NULL, "y 符号与 ydown 不配：(w+y) 配 ydown = 0 期望 NULL");
    CHECK(ask(P_p, 128, 0, 1, 0) != NULL, "对照：(w+y) 配 ydown = 1 期望给变体");
    CHECK(ask(P_x, 128, 0, 1, 0) == NULL && ask(P_x, 128, 0, 0, 0) == NULL, "x 用 (w−x)：期望 NULL");
    CHECK(ask(P_n, 128, 0, 1, 0) == NULL && ask(P_n, 128, 0, 0, 0) == NULL, "坐标没除 w（不是当前像素）：期望 NULL");
    CHECK(ask(P_o, 128, 0, 1, 0) == NULL, "采样的是别的贴图：命中附件的绑定 128 在右邻像素采样，期望 NULL");
    CHECK(wait_variant(P_o, 129, 0, 1) != NULL, "对照：同一程序在当前像素采样的绑定 129 期望给变体");
    CHECK(ask(P_p, 128, 0, 1, 1) == NULL, "缩放位为 1（非归一化坐标，坐标 ÷ 贴图尺寸）：期望 NULL");
    { uint8_t b[2] = {128, 129}, s[2] = {0, 0}; set_ubo(0);
      CHECK(gal_prog_fbfetch(gal_prog_get(P_p), b, s, 2, 1) == NULL, "要改读的绑定里有一个（129）没声明 / 证不出：期望 NULL"); }
    printf("· 反例（绘制）：(w−y) 程序配正向视口 → 翻译器不给 → 照旧拆遍\n");
    { static uint8_t a[4096], b[4096]; uint64_t f; uint64_t e = run(P_m, 128, 0, 0, a, b, &f);
      CHECK(e == 2 && f == 0, "y 符号不配：期望渲染编码器 2 个 / 改读 0 次，实得 %llu / %llu", (unsigned long long)e, (unsigned long long)f);
      // 这时原采样落在上下镜像的位置（B 第 y 行 = A 第 31−y 行）：若误给变体，B 会等于 A——画错
      int bad = 0; for (int y = 0; y < 32; y++) bad += memcmp(b + y * 128, a + (31 - y) * 128, 128) != 0;
      CHECK(bad == 0, "y 符号不配：拆遍结果期望是 A 上下镜像（证明此时改读帧缓冲会画错），实得 %d 行不符", bad); }
    { uint64_t f; uint64_t e = run(P_p, 128, 0, 1, NULL, NULL, &f);
      CHECK(e == 2 && f == 0, "缩放位为 1：期望渲染编码器 2 个 / 改读 0 次，实得 %llu / %llu", (unsigned long long)e, (unsigned long long)f); }

    nxgal_shutdown();
    printf("%s：%d / %d 项通过\n", g_fail ? "失败" : "通过", g_checks - g_fail, g_checks);
    return g_fail ? 1 : 0;
}
GAL_MTL4_ZONE_END
