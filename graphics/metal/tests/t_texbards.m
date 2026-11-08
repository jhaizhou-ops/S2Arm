// TextureBarrier 后采样本遍深度附件（gal_draw.m texbar_ds_inplace / gal_pass.m g_ds_mem）单测：
// 深度自开遍载入后本遍没写过、本次绘制也不写 → 内存那份就是最新值，就地采样、不收遍；否则照旧收遍。
// 程序复用 t_fbfetch 的手写 SPIR-V：写入绘制 vsp + pat（深度 = 顶点 z），采样绘制 vsp + fsf（loc1 = texture(集 2 绑定 0, 屏幕坐标)，最近点）。
// 期望值不经被测逻辑：B 的红通道应等于同一时刻深度贴图读回值 × 255（±1）；编码器数按场景手算：
//   X 写深度 → 屏障采样（脏，收：2 个）→ 再屏障采样（干净，就地：仍 2 个），B = 深度
//   Y 写深度 → 屏障采样（收：2 个）→ 写新深度 → 屏障采样（脏，收：3 个），B = 新深度
//   Z 以清屏开遍、只画颜色 → 屏障采样（开遍不是从内存载入，收：2 个），B = 清屏值
#import <Metal/Metal.h>
#include "../gal_abi.h"
#include "../gal_internal.h"
#include <libgen.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

GAL_MTL4_ZONE_BEGIN
extern uint64_t g_texbar_ds_inplace;
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
enum { RGBA8 = 36, D32F = 51 };
static nxgal_tex_info ti(int w, int h, int fmt, int bpp) { nxgal_tex_info i = {w, h, 1, 1, 1, 1, 1, bpp, fmt, 0, 1, {2, 3, 4, 5}}; return i; }
static uint32_t P_wr, P_samp, g_smp;

static void set_ubo(void) { float c[4] = {1, 1, 1, 1}; uint32_t u = nxgal_buf_create(16, 0); nxgal_buf_set_data(u, 0, c, 16); nxgal_buf_assign a0 = {0, {u, 0, 16, 0}}; nxgal_set_uniform_buffers(&a0, 1); }
static void set_quad(float z) {
    float v[12] = {-1, -1, z, 1, -1, z, 1, 1, z, -1, 1, z};
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
static void clear_depth(float v) { nxgal_rect full = {0, 0, 0xffff, 0xffff}; nxgal_set_scissors(&full, 1); nxgal_clear_ds(0, 1, v, 1, 0, 0); nxgal_rect sc = {0, 0, 32, 32}; nxgal_set_scissors(&sc, 1); }
// 写深度（深度测试恒过、写开）；只写颜色槽 0
static void draw_write_depth(float z) {
    nxgal_depth_test d = {1, 1, 8 /* Always */}; nxgal_set_depth_test(&d);
    uint32_t m[8] = {0xf, 0, 0, 0, 0, 0, 0, 0}; nxgal_set_color_masks(m, 8);
    set_quad(z); nxgal_set_program(P_wr); nxgal_draw(4, 1, 0, 0);
}
// 只画颜色槽 0、深度不测不写
static void draw_color_only(void) {
    nxgal_depth_test d = {0, 0, 8}; nxgal_set_depth_test(&d);
    uint32_t m[8] = {0xf, 0, 0, 0, 0, 0, 0, 0}; nxgal_set_color_masks(m, 8);
    set_quad(0.5f); nxgal_set_program(P_wr); nxgal_draw(4, 1, 0, 0);
}
// 屏障 + 采样深度写进颜色槽 1（深度不测不写）
static void barrier_sample(uint32_t D) {
    nxgal_barrier(2);   // TextureBarrier
    nxgal_depth_test d = {0, 0, 8}; nxgal_set_depth_test(&d);
    uint32_t m[8] = {0, 0xf, 0, 0, 0, 0, 0, 0}; nxgal_set_color_masks(m, 8);
    nxgal_set_texture_sampler(5, 0, D, g_smp);
    set_quad(0.5f); nxgal_set_program(P_samp); nxgal_draw(4, 1, 0, 0);
}
typedef struct { uint64_t enc, inplace; int bad, n; float d0; uint8_t b0; } res;
// 跑一个场景：steps 由调用方给；结束后读回 B 与 D，逐像素比 B.r 与 round(D × 255)
static res scene(void (*steps)(uint32_t D)) {
    nxgal_tex_info ci = ti(32, 32, RGBA8, 4), di = ti(32, 32, D32F, 4);
    uint32_t A = nxgal_tex_create(&ci), B = nxgal_tex_create(&ci), D = nxgal_tex_create(&di);
    uint32_t ab[2] = {A, B}; nxgal_set_render_targets(ab, 2, D);
    base_state(); set_ubo();
    float z[4] = {0, 0, 0, 0}; nxgal_clear_color(1, 0, 1, 0xf, z);
    uint64_t e0 = g_gp_n[GP_RENC], i0 = g_texbar_ds_inplace;
    steps(D);
    res r = {g_gp_n[GP_RENC] - e0, g_texbar_ds_inplace - i0, 0, 32 * 32, 0, 0};
    static uint8_t b[4096]; static float d[1024];
    nxgal_tex_get_data(B, 0, 0, b, sizeof b); nxgal_tex_get_data(D, 0, 0, d, sizeof d);
    for (int i = 0; i < 1024; i++) if (abs((int)b[i * 4] - (int)lround(d[i] * 255.0)) > 1) r.bad++;
    r.d0 = d[0]; r.b0 = b[0];
    nxgal_set_texture_sampler(5, 0, 0, 0);
    nxgal_tex_release(A); nxgal_tex_release(B); nxgal_tex_release(D);
    return r;
}
static void steps_x(uint32_t D) { clear_depth(1.0f); draw_write_depth(0.25f); barrier_sample(D); barrier_sample(D); }
static void steps_y(uint32_t D) { clear_depth(1.0f); draw_write_depth(0.25f); barrier_sample(D); draw_write_depth(0.6f); barrier_sample(D); }
static void steps_z(uint32_t D) { clear_depth(0.75f); draw_color_only(); barrier_sample(D); }

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    (void)argc; char exe[1024]; snprintf(exe, sizeof exe, "%s", argv[0]); snprintf(g_dir, sizeof g_dir, "%s/t_fbr_in", dirname(exe));
    if (nxgal_init(0)) return 2;
    P_wr = prog("vsp", "pat"); P_samp = prog("vsp", "fsf");
    nxgal_sampler_info si = {0, 0, 0, 2, 2, 2, 0, 8, {0, 0, 0, 0}, 0, 1000, 0, 1};   // 最近点、夹边、不比较
    g_smp = nxgal_sampler_create(&si);

    printf("· X 写深度 → 屏障采样（收）→ 再屏障采样（干净：就地、不收）：渲染编码器 2 个、就地 1 次，B = 深度\n");
    res x = scene(steps_x);
    CHECK(x.enc == 2 && x.inplace == 1, "X 期望渲染编码器 2 个 / 就地 1 次，实得 %llu / %llu", (unsigned long long)x.enc, (unsigned long long)x.inplace);
    CHECK(x.bad == 0, "X 期望 B 红通道逐像素 = 深度 × 255（±1），%d / %d 像素不符（深度 %g、B %u）", x.bad, x.n, x.d0, x.b0);
    printf("· Y 写深度 → 屏障采样（收）→ 写新深度 → 屏障采样（脏：收）：渲染编码器 3 个、就地 0 次，B = 新深度\n");
    res y = scene(steps_y);
    CHECK(y.enc == 3 && y.inplace == 0, "Y 期望渲染编码器 3 个 / 就地 0 次，实得 %llu / %llu", (unsigned long long)y.enc, (unsigned long long)y.inplace);
    CHECK(y.bad == 0 && fabsf(y.d0 - x.d0) > 0.1f, "Y 期望 B = 新深度（与 X 的深度不同），%d 像素不符（深度 %g 对 X %g、B %u）", y.bad, y.d0, x.d0, y.b0);
    printf("· Z 以清屏开遍、只画颜色 → 屏障采样（开遍不是从内存载入：收）：渲染编码器 2 个、就地 0 次，B = 清屏值 0.75\n");
    res z = scene(steps_z);
    CHECK(z.enc == 2 && z.inplace == 0, "Z 期望渲染编码器 2 个 / 就地 0 次，实得 %llu / %llu", (unsigned long long)z.enc, (unsigned long long)z.inplace);
    CHECK(z.bad == 0 && fabsf(z.d0 - 0.75f) < 1e-6f, "Z 期望 B = 清屏值 0.75，%d 像素不符（深度 %g、B %u）", z.bad, z.d0, z.b0);

    nxgal_shutdown();
    printf("%s：%d / %d 项通过\n", g_fail ? "失败" : "通过", g_checks - g_fail, g_checks);
    return g_fail ? 1 : 0;
}
GAL_MTL4_ZONE_END
