// 读帧缓冲证明随程序二进制持久化（gal_fbr.m 尾段 + gal_prog.m BIN_VERSION 2，10-22）单测：真机程序走 load_binary（没有 SPIR-V），原先 p->fbr 恒空、读帧缓冲改写一次都不生效。
// 输入：t_fbr 的手写 SPIR-V（t_fbr_in/）+ 出包那条路造的离线库（t_fbrp_in/，tests/t_fbrp_lib.sh：gal_xc --fbr 证明 + 按请求改写 → gal_offline.py）。
// 期望值手算（不跑被测实现）：片元 t_fbr_fs 采样集 2 绑定 128，缩放因子位 = 集 0 绑定 0 常量缓冲成员 1（偏移 16）的 .z（+8）第 0 位 → 条件 {常量缓冲 0, 字节偏移 24, 位 0, 贴图绑定 128}；
//   顶点 t_fbr_vsp 写 (w+y)·0.5 → 只在 ydown = 1 时是当前像素 → ok[1][128 >> 6 = 2] = 1 << 0，其余 ok 字全 0。
// a 现编程序 binary → release → load_binary：恢复出的证明逐字段 = 现编时的证明 = 手算值，且不留 SPIR-V
// b 变体表命中：load_binary 后 gal_prog_fbfetch 当场取到变体（不挂起）、「着色器首遇现编」0 条、运行时现编计数 +0；出图与现编变体逐字节相同（且 B = A）；
//   出包尾段（gal_xc --fbr 的 P 行）与运行时尾段逐字节相同，接在同一份记录后 load_binary 同样命中
// c 不在表里（没有 SPIR-V）：返回 NULL，记一行「读帧缓冲变体缺 v1 <顶点键> <片元键> <ydown> <绑定:槽>」（字段按手算核对），同一映射只记一次
// e 宽屏外推尾声（graphics/widen/shader/SpirvEdgePush.cs，手写 t_fbr_vsep / t_fbr_vse：独立 gl_Position 变量 / gl_PerVertex 块两种形态）：
//   条件手算：s2a_widen 在支持缓冲（集 0 绑定 0）成员 2、偏移 32 → .x 在字节 32、.z 在字节 40，两条「按浮点为 0」条件挂在贴图绑定 128 上（加片元缩放位条件共 3 条）；
//   .x、.z 都为 ±0 → 给变体、不拆遍、B = A；.x 或 .z 非 0（外推开，光栅化位置 ≠ locK）→ NULL；二进制往返后条件种类照样恢复
// d BIN_VERSION 1 的旧二进制（去掉尾段、版本写 1；另带一段尾随字节）照样建成、没有证明；版本 2 尾段坏 → 二进制坏（不静默丢证明）
// 旧代码反证（e）：同一份测试对旧实现（gal_*.m 换成改动前的，头文件照新版、链接放行未定义的 _gal_fbr_view_of）编、跑，a（load_binary 后 p->fbr 为空）/ b（不给变体）期望不通过
#import <Metal/Metal.h>
#include "../gal_abi.h"
#include "../gal_internal.h"
#include <fcntl.h>
#include <libgen.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

GAL_MTL4_ZONE_BEGIN
extern uint64_t g_fbfetch_draws;
const gal_prog *gal_prog_fbfetch(const gal_prog *pg, const uint8_t *bind, const uint8_t *slot, int n, int ydown);
// 旧代码没有它（反证编译时链接放行未定义）：弱引用，缺了按「读不到证明字段」判失败
__attribute__((weak)) void gal_fbr_view_of(const gal_fbr *f, gal_fbr_view *v);
static int g_fail, g_checks;
#define CHECK(cond, ...) do { g_checks++; if (!(cond)) { g_fail++; printf("  ✗ " __VA_ARGS__); printf("\n"); } } while (0)

static char g_dir[1024], g_in[1100];
static uint8_t *slurp(const char *p, uint32_t *len) {
    FILE *f = fopen(p, "rb"); if (!f) return NULL;
    fseek(f, 0, SEEK_END); long l = ftell(f); fseek(f, 0, SEEK_SET);
    uint8_t *b = malloc((size_t)l + 1); if (fread(b, 1, (size_t)l, f) != (size_t)l) exit(2);
    b[l] = 0; fclose(f); *len = (uint32_t)l; return b;
}
static uint8_t *load(const char *name, uint32_t *len) {
    char p[1200]; snprintf(p, sizeof p, "%s/t_fbr_in/%s.spv", g_dir, name);
    uint8_t *b = slurp(p, len); if (!b) { printf("读不了 %s\n", p); exit(2); } return b;
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
// 宽屏外推参数 s2a_widen.x（外推量）/ .z（横向收缩量），浮点位：支持缓冲字节 32 / 40（t_fbr_vse / t_fbr_vsep 的成员 2）
static uint32_t g_wd, g_wz;
static void set_ubo(int flag) {
    uint32_t c[12] = {0x3f800000u, 0x3f800000u, 0x3f800000u, 0x3f800000u, 0, 0, (uint32_t)flag, 0, g_wd, 0, g_wz, 0};
    if (!g_ubo) g_ubo = nxgal_buf_create(48, 0);
    nxgal_buf_set_data(g_ubo, 0, c, 48); nxgal_buf_assign a0 = {0, {g_ubo, 0, 48, 0}}; nxgal_set_uniform_buffers(&a0, 1);
}
static void set_quad(void) {
    float v[12] = {-1, -1, 0.5f, 1, -1, 0.5f, 1, 1, 0.5f, -1, 1, 0.5f};
    uint32_t b = nxgal_buf_create(48, 0); nxgal_buf_set_data(b, 0, v, 48);
    nxgal_vbuf vb = {{b, 0, 48, 0}, 12, 0}; nxgal_set_vertex_buffers(&vb, 1);
    nxgal_vattr at = {0, 0, 0, 33}; nxgal_set_vertex_attribs(&at, 1); nxgal_set_topology(7);
}
// 正向视口（ydown = 1，配 (w+y) 的 t_fbr_vsp）
static void base_state(void) {
    nxgal_blend b = {0, {0, 0, 0, 0}, 1, 2, 1, 1, 2, 1}; for (int i = 0; i < 8; i++) nxgal_set_blend(i, &b);
    nxgal_depth_test d = {0, 0, 8}; nxgal_set_depth_test(&d);
    nxgal_stencil s; memset(&s, 0, sizeof s); nxgal_set_stencil_test(&s);
    nxgal_set_face_culling(0, 0x405); nxgal_set_front_face(0x901);
    nxgal_viewport vp = {0, 0, 32, 32, {0, 2, 4, 6}, 0, 1}; nxgal_set_viewports(&vp, 1);
    nxgal_rect sc = {0, 0, 32, 32}; nxgal_set_scissors(&sc, 1);
    uint32_t m[8] = {0xf, 0xf, 0xf, 0xf, 0xf, 0xf, 0xf, 0xf}; nxgal_set_color_masks(m, 8);
}
static uint32_t g_smp, g_pat;
// 同 t_fbr：第一次绘制写 A（槽 0）渐变；TextureBarrier；第二次在当前像素采样 A 写 B。返回渲染编码器数，*fetched = 改读帧缓冲的绘制数
static uint64_t run(uint32_t samp, uint8_t *a, uint8_t *b, uint64_t *fetched) {
    nxgal_tex_info ci = ti(32, 32, RGBA8, 4);
    uint32_t A = nxgal_tex_create(&ci), B = nxgal_tex_create(&ci);
    uint32_t ab[2] = {A, B}; nxgal_set_render_targets(ab, 2, 0);
    base_state(); set_ubo(0); set_quad();
    uint64_t e0 = g_gp_n[GP_RENC], f0 = g_fbfetch_draws;
    nxgal_set_program(g_pat); nxgal_draw(4, 1, 0, 0);
    nxgal_barrier(2);
    uint32_t m[8] = {0, 0xf, 0xf, 0xf, 0xf, 0xf, 0xf, 0xf}; nxgal_set_color_masks(m, 8);
    nxgal_set_texture_sampler(5, 128, A, g_smp);
    nxgal_set_program(samp); nxgal_draw(4, 1, 0, 0);
    uint64_t enc = g_gp_n[GP_RENC] - e0; *fetched = g_fbfetch_draws - f0;
    if (a) nxgal_tex_get_data(A, 0, 0, a, 4096);
    if (b) nxgal_tex_get_data(B, 0, 0, b, 4096);
    nxgal_set_texture_sampler(5, 128, 0, 0);
    nxgal_tex_release(A); nxgal_tex_release(B);
    return enc;
}
static const gal_prog *ask(uint32_t pid, uint8_t bind, uint8_t slot, int ydown) {
    nxgal_tex_info ci = ti(32, 32, RGBA8, 4);
    uint32_t A = nxgal_tex_create(&ci), B = nxgal_tex_create(&ci); uint32_t ab[2] = {A, B}; nxgal_set_render_targets(ab, 2, 0); set_ubo(0);
    const gal_prog *v = gal_prog_fbfetch(gal_prog_get(pid), &bind, &slot, 1, ydown);
    nxgal_tex_release(A); nxgal_tex_release(B);
    return v;
}
static const gal_prog *wait_variant(uint32_t pid, uint8_t bind, uint8_t slot, int ydown) {
    for (int i = 0; i < 1000; i++) { const gal_prog *v = ask(pid, bind, slot, ydown); if (v) return v; usleep(20000); }
    return NULL;
}
static int diff_px(const uint8_t *x, const uint8_t *y) { int n = 0; for (int i = 0; i < 1024; i++) n += memcmp(x + 4 * i, y + 4 * i, 4) != 0; return n; }
// stderr 截到文件（GLOG 写 stderr）：begin 后到 end 之间的日志读回成串
static int g_saved = -1; static char g_cap[1200];
static void cap_begin(void) { fflush(stderr); snprintf(g_cap, sizeof g_cap, "%s/cap.log", g_in); int fd = open(g_cap, O_WRONLY | O_CREAT | O_TRUNC, 0644); g_saved = dup(2); dup2(fd, 2); close(fd); }
static char *cap_end(void) { fflush(stderr); dup2(g_saved, 2); close(g_saved); uint32_t l; char *s = (char *)slurp(g_cap, &l); fputs(s ? s : "", stderr); return s ? s : strdup(""); }
static int count(const char *s, const char *w) { int n = 0; for (const char *p = s; (p = strstr(p, w)); p += strlen(w)) n++; return n; }
// 手算的证明（见文件头）
static int view_is_expected(const gal_fbr_view *v) {
    for (int y = 0; y < 2; y++) for (int w = 0; w < 4; w++) if (v->ok[y][w] != (y == 1 && w == 2 ? 1ull : 0ull)) return 0;
    return v->ncond == 1 && v->cubo[0] == 0 && v->coff[0] == 24 && v->cbit[0] == 0 && v->cbind[0] == 128 && v->ckind[0] == 0;
}
// 带外推尾声的手算证明：ok[ydown][2] = 1；条件 = 片元缩放位 {0, 24, 位 0} + 外推 .x {0, 32, 浮点 0} + .z {0, 40, 浮点 0}，都挂绑定 128
static int view_push_expected(const gal_fbr_view *v, int ydown) {
    for (int y = 0; y < 2; y++) for (int w = 0; w < 4; w++) if (v->ok[y][w] != (y == ydown && w == 2 ? 1ull : 0ull)) return 0;
    static const uint32_t off[3] = {24, 32, 40}; static const uint8_t kind[3] = {0, 1, 1};
    if (v->ncond != 3) return 0;
    for (int k = 0; k < 3; k++) if (v->cubo[k] != 0 || v->coff[k] != off[k] || v->cbit[k] != 0 || v->cbind[k] != 128 || v->ckind[k] != kind[k]) return 0;
    return 1;
}
static int view_eq(const gal_fbr_view *x, const gal_fbr_view *y) {
    if (memcmp(x->ok, y->ok, sizeof x->ok) || x->ncond != y->ncond) return 0;
    for (int k = 0; k < x->ncond; k++) if (x->cubo[k] != y->cubo[k] || x->coff[k] != y->coff[k] || x->cbit[k] != y->cbit[k] || x->cbind[k] != y->cbind[k] || x->ckind[k] != y->ckind[k]) return 0;
    return 1;
}
static uint32_t rd32(const uint8_t *p) { uint32_t v; memcpy(&v, p, 4); return v; }
// 程序二进制里记录部分的长度（头 20 字节 + m 个 {u32 长, 记录}）
static uint32_t rec_end(const uint8_t *b) { uint32_t q = 20, m = rd32(b + 12); for (uint32_t i = 0; i < m; i++) q += 4 + rd32(b + q); return q; }

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    char exe[1024]; snprintf(exe, sizeof exe, "%s", argv[0]); snprintf(g_dir, sizeof g_dir, "%s", dirname(exe));
    snprintf(g_in, sizeof g_in, "%s", argc > 1 ? argv[1] : "");
    if (!g_in[0]) snprintf(g_in, sizeof g_in, "%s/t_fbrp_in", g_dir);
    char p[1300]; uint32_t l;
    snprintf(p, sizeof p, "%s/keys.txt", g_in); char *ks = (char *)slurp(p, &l); if (!ks) { printf("读不了 %s（先跑 tests/t_fbrp_lib.sh）\n", p); return 2; }
    unsigned long long K_vs, K_vsp, K_fs, K_vsep; if (sscanf(ks, "%llx %llx %llx %llx", &K_vs, &K_vsp, &K_fs, &K_vsep) != 4) return 2;
    snprintf(p, sizeof p, "%s/fbr.tsv", g_in); char *ft = (char *)slurp(p, &l); if (!ft) return 2;
    // 出包表：(vsp, fs) 的 P 行尾段与 V 行变体片元键
    uint8_t bake_tr[512]; int bake_tl = 0; unsigned long long K_var = 0;
    { char pk[64]; snprintf(pk, sizeof pk, "P\t%016llx\t%016llx\t", K_vsp, K_fs); char *q = strstr(ft, pk);
      if (q) { q += strlen(pk); while (bake_tl < 512 && q[0] && q[0] != '\n') { unsigned x; sscanf(q, "%2x", &x); bake_tr[bake_tl++] = (uint8_t)x; q += 2; } }
      snprintf(pk, sizeof pk, "V\t%016llx\t%016llx\t1\t", K_vsp, K_fs); q = strstr(ft, pk); if (q) sscanf(q + strlen(pk), "%llx", &K_var); }
    uint8_t bake_tre[512]; int bake_tle = 0;
    { char pk[64]; snprintf(pk, sizeof pk, "P\t%016llx\t%016llx\t", K_vsep, K_fs); char *q = strstr(ft, pk);
      if (q) { q += strlen(pk); while (bake_tle < 512 && q[0] && q[0] != '\n') { unsigned x; sscanf(q, "%2x", &x); bake_tre[bake_tle++] = (uint8_t)x; q += 2; } } }
    if (!bake_tl || !K_var) { printf("fbr.tsv 里没有 (vsp, fs) 的 P / V 行\n"); return 2; }
    if (nxgal_init(0)) return 2;
    nxgal_sampler_info si = {2, 2, 0, 2, 2, 2, 0, 8, {0, 0, 0, 0}, 0, 1000, 0, 1};
    g_smp = nxgal_sampler_create(&si);
    g_pat = prog("vsp", "pat");
    int have_view = gal_fbr_view_of != NULL;
    CHECK(have_view, "读不到证明字段（没有 gal_fbr_view_of：旧代码）");

    printf("· e 宽屏外推尾声：两种 gl_Position 形态都证得（条件 = 手算）；外推参数 .x、.z 为 ±0 → 变体、不拆遍、B = A；任一非 0 → NULL / 照旧拆遍\n");
    uint32_t PE = prog("vsep", "fs"), PB = prog("vse", "fs");
    gal_fbr_view ve, vbk; memset(&ve, 0, sizeof ve); memset(&vbk, 0, sizeof vbk);
    if (have_view) { gal_fbr_view_of(gal_prog_get(PE)->fbr, &ve); gal_fbr_view_of(gal_prog_get(PB)->fbr, &vbk); }
    CHECK(view_push_expected(&ve, 1), "独立 gl_Position 形态：期望 ok[1][2] = 1、条件 3 条 {24 位 0 / 32 浮点 0 / 40 浮点 0}，实得 ok[1][2] = %llx、条件 %d 条", (unsigned long long)ve.ok[1][2], ve.ncond);
    CHECK(view_push_expected(&vbk, 0), "gl_PerVertex 块形态：期望 ok[0][2] = 1、条件 3 条，实得 ok[0][2] = %llx、条件 %d 条", (unsigned long long)vbk.ok[0][2], vbk.ncond);
    g_wd = g_wz = 0;
    const gal_prog *ve1 = wait_variant(PE, 128, 0, 1);
    CHECK(ve1 != NULL, "外推参数为 0：期望 20 秒内拿到变体，实得 NULL");
    static uint8_t ae[4096], be[4096]; uint64_t fe; uint64_t ee = ve1 ? run(PE, ae, be, &fe) : 0;
    CHECK(ve1 && ee == 1 && fe == 1 && diff_px(ae, be) == 0, "外推参数为 0：期望不拆遍（编码器 1 / 改读 1）且 B 逐像素 = A，实得 %llu / %llu、差 %d 像素", (unsigned long long)ee, (unsigned long long)fe, diff_px(ae, be));
    g_wz = 0x80000000u;
    CHECK(ask(PE, 128, 0, 1) != NULL, "横向收缩量 −0：期望照样给变体（正负零都算）");
    g_wz = 0; g_wd = 0x3e800000u;
    CHECK(ask(PE, 128, 0, 1) == NULL, "外推量 0.25：期望 NULL");
    { uint64_t f; uint64_t e = run(PE, NULL, NULL, &f); CHECK(e == 2 && f == 0, "外推量 0.25 绘制：期望照旧拆遍（编码器 2 / 改读 0），实得 %llu / %llu", (unsigned long long)e, (unsigned long long)f); }
    g_wd = 0; g_wz = 0x3dcccccdu;
    CHECK(ask(PE, 128, 0, 1) == NULL, "横向收缩量 0.1：期望 NULL");
    g_wz = 0;
    CHECK(wait_variant(PB, 128, 0, 0) != NULL, "块形态、外推参数为 0、ydown 0：期望给变体");
    g_wd = 0x3e800000u; CHECK(ask(PB, 128, 0, 0) == NULL, "块形态、外推量 0.25：期望 NULL"); g_wd = 0;
    int32_t ne = nxgal_prog_binary(PE, NULL, 0); uint8_t *bine = malloc(ne > 0 ? ne : 1); CHECK(ne > 20 && nxgal_prog_binary(PE, bine, ne) == ne, "取外推程序二进制失败");
    {   uint32_t q = ne > 20 ? rec_end(bine) : 20, tl = ne > (int32_t)q ? (uint32_t)ne - q : 0;
        CHECK(tl == 4 + 64 + 4 + 3 * 10 + 4 + 26 && tl == (uint32_t)bake_tle && !memcmp(bine + q, bake_tre, tl),
              "外推程序：出包尾段（gal_xc --fbr）期望与运行时尾段逐字节相同、134 字节（3 条条件 + 1 个变体），实得 %d / %u 字节", bake_tle, tl); }
    nxgal_prog_release(PE); nxgal_prog_release(PB);

    printf("· a 现编程序：证明 = 手算；建成变体、取二进制（版本 2 带尾段）→ release → 清缓存 + 关现编 + 开离线库 → load_binary：证明逐字段相同、不留 SPIR-V\n");
    uint32_t P = prog("vsp", "fs");
    gal_fbr_view v0, v1; memset(&v0, 0, sizeof v0); memset(&v1, 0, sizeof v1);
    if (have_view) gal_fbr_view_of(gal_prog_get(P)->fbr, &v0);
    CHECK(view_is_expected(&v0), "现编证明期望 ok[1][2] = 1、条件 {0, 24, 0, 128}，实得 ok[1][2] = %llx、条件 %d 个 {%u, %u, %u, %u}",
          (unsigned long long)v0.ok[1][2], v0.ncond, v0.cubo[0], v0.coff[0], v0.cbit[0], v0.cbind[0]);
    const gal_prog *vr = NULL; for (int i = 0; i < 1000 && !vr; i++) { vr = ask(P, 128, 0, 1); if (!vr) usleep(20000); }
    CHECK(vr != NULL, "现编变体 20 秒内没建成");
    CHECK(vr && vr->stage_hash[5] == K_var, "运行时改写的变体片元键期望 = 出包 gal_xc --fbr 的 %016llx，实得 %016llx", K_var, vr ? (unsigned long long)vr->stage_hash[5] : 0ull);
    static uint8_t a_rt[4096], b_rt[4096]; uint64_t f_rt; uint64_t e_rt = run(P, a_rt, b_rt, &f_rt);
    CHECK(e_rt == 1 && f_rt == 1, "现编变体：期望不拆遍（编码器 1 / 改读 1），实得 %llu / %llu", (unsigned long long)e_rt, (unsigned long long)f_rt);
    CHECK(diff_px(a_rt, b_rt) == 0, "现编变体：B 期望逐像素等于 A，实得 %d 像素不同", diff_px(a_rt, b_rt));
    int32_t n = nxgal_prog_binary(P, NULL, 0); uint8_t *bin = malloc(n > 0 ? n : 1); CHECK(n > 20 && nxgal_prog_binary(P, bin, n) == n, "取二进制失败（%d）", n);
    uint32_t re = n > 20 ? rec_end(bin) : 20, rt_tl = n > (int32_t)re ? (uint32_t)n - re : 0;
    CHECK(n > 20 && rd32(bin + 4) == 2, "二进制版本期望 2，实得 %u", n > 20 ? rd32(bin + 4) : 0);
    CHECK(rt_tl == 4 + 64 + 4 + 10 + 4 + 26, "尾段期望 112 字节（1 条条件 + 1 个变体），实得 %u", rt_tl);
    CHECK(rt_tl == (uint32_t)bake_tl && !memcmp(bin + re, bake_tr, rt_tl), "出包尾段（gal_xc --fbr）期望与运行时尾段逐字节相同（%d / %u 字节）", bake_tl, rt_tl);
    nxgal_prog_release(P);
    nxgal_prog_cache_clear(); nxgal_prog_set_xc(0);
    snprintf(p, sizeof p, "%s/lib", g_in); CHECK(nxgal_prog_lib_open(p) == 0, "开离线库失败：%s", nxgal_prog_last_error());
    uint32_t P2 = nxgal_prog_load_binary(bin, n, 1);
    CHECK(nxgal_prog_status(P2, 1) == 0, "load_binary 失败：%s", nxgal_prog_last_error());
    gal_prog *q2 = gal_prog_get(P2);
    CHECK(q2 && q2->fbr, "load_binary 后期望有证明（p->fbr 非空），实得空");
    if (have_view && q2) gal_fbr_view_of(q2->fbr, &v1);
    CHECK(view_eq(&v0, &v1) && view_is_expected(&v1), "恢复的证明期望逐字段 = 现编证明 = 手算，实得 ok[1][2] = %llx、条件 %d 个 {%u, %u, %u, %u}",
          (unsigned long long)v1.ok[1][2], v1.ncond, v1.cubo[0], v1.coff[0], v1.cbit[0], v1.cbind[0]);
    CHECK(have_view && v1.has_fs == 0 && v1.nvar == 1, "恢复的证明期望不留 SPIR-V、变体表 1 条，实得 has_fs %d / 变体 %d", v1.has_fs, v1.nvar);

    printf("· b 变体表命中：load_binary 的程序当场取到变体，「着色器首遇现编」0 条、现编 +0；出图与现编变体逐字节相同\n");
    uint32_t s0[6], s1[6]; nxgal_prog_stats(s0);
    cap_begin();
    const gal_prog *vb = ask(P2, 128, 0, 1);
    static uint8_t a2[4096], b2[4096]; uint64_t f2 = 0, e2 = vb ? run(P2, a2, b2, &f2) : 0;
    char *lg = cap_end(); nxgal_prog_stats(s1);
    CHECK(vb != NULL, "变体表命中期望当场给变体，实得 NULL");
    CHECK(vb && vb->stage_hash[5] == K_var && vb->stage_hash[1] == K_vsp, "变体期望 = （顶点 %016llx + 变体片元 %016llx），实得 %016llx + %016llx", K_vsp, K_var,
          vb ? (unsigned long long)vb->stage_hash[1] : 0ull, vb ? (unsigned long long)vb->stage_hash[5] : 0ull);
    CHECK(count(lg, "着色器首遇现编") == 0 && s1[4] == s0[4], "期望「着色器首遇现编」0 条、运行时现编 +0，实得 %d 条、+%u", count(lg, "着色器首遇现编"), s1[4] - s0[4]);
    CHECK(s1[2] - s0[2] == 1, "变体片元期望从离线库取 1 支，实得 +%u", s1[2] - s0[2]);
    CHECK(e2 == 1 && f2 == 1, "load_binary 程序：期望不拆遍（编码器 1 / 改读 1），实得 %llu / %llu", (unsigned long long)e2, (unsigned long long)f2);
    CHECK(vb && !memcmp(a2, a_rt, 4096) && !memcmp(b2, b_rt, 4096), "出图期望与现编变体逐字节相同（A 差 %d、B 差 %d 像素）", diff_px(a2, a_rt), diff_px(b2, b_rt));
    free(lg);
    {   // 出包二进制 = 同一份记录 + gal_xc --fbr 的尾段（ShaderBake.cs Galp 的拼法）
        uint8_t *bb = malloc(re + bake_tl); memcpy(bb, bin, re); memcpy(bb + re, bake_tr, bake_tl); memcpy(bb + 4, &(uint32_t){2}, 4);
        uint32_t P3 = nxgal_prog_load_binary(bb, (int32_t)(re + bake_tl), 1); free(bb);
        CHECK(nxgal_prog_status(P3, 1) == 0, "出包二进制 load_binary 失败：%s", nxgal_prog_last_error());
        gal_fbr_view v3; memset(&v3, 0, sizeof v3); if (have_view && gal_prog_get(P3)) gal_fbr_view_of(gal_prog_get(P3)->fbr, &v3);
        CHECK(view_eq(&v0, &v3) && v3.nvar == 1, "出包二进制恢复的证明期望 = 现编证明、变体 1 条");
        const gal_prog *v3p = ask(P3, 128, 0, 1);
        CHECK(v3p && v3p->stage_hash[5] == K_var, "出包二进制：期望按表取到变体 %016llx", K_var);
        nxgal_prog_release(P3);
    }

    {   // e 续：外推程序二进制往返——条件种类恢复，按表取变体；外推量非 0 照样 NULL
        uint32_t PE2 = nxgal_prog_load_binary(bine, ne, 1);
        gal_fbr_view ve2; memset(&ve2, 0, sizeof ve2); if (have_view && gal_prog_get(PE2)) gal_fbr_view_of(gal_prog_get(PE2)->fbr, &ve2);
        CHECK(nxgal_prog_status(PE2, 1) == 0 && view_eq(&ve, &ve2) && view_push_expected(&ve2, 1) && ve2.nvar == 1, "外推程序 load_binary：期望证明逐字段（含条件种类）= 现编、变体表 1 条");
        g_wd = g_wz = 0; const gal_prog *x1 = ask(PE2, 128, 0, 1);
        CHECK(x1 && x1->stage_hash[5] == K_var, "外推程序 load_binary、外推参数为 0：期望按表当场取到变体 %016llx", K_var);
        g_wd = 0x3e800000u; CHECK(ask(PE2, 128, 0, 1) == NULL, "外推程序 load_binary、外推量 0.25：期望 NULL"); g_wd = 0;
        nxgal_prog_release(PE2); free(bine);
    }

    printf("· c 不在表里且没有 SPIR-V：返回 NULL，记一行「读帧缓冲变体缺」（同一映射只记一次）\n");
    cap_begin();
    const gal_prog *vc = ask(P2, 128, 1, 1), *vc2 = ask(P2, 128, 1, 1);
    lg = cap_end();
    CHECK(vc == NULL && vc2 == NULL, "映射 128 → 槽 1 不在变体表里：期望 NULL");
    char want[200]; snprintf(want, sizeof want, "读帧缓冲变体缺 v1 %016llx %016llx 1 128:1\n", K_vsp, K_fs);
    CHECK(count(lg, want) == 1 && count(lg, "读帧缓冲变体缺") == 1, "期望恰好一行「%.*s」，实得 %d 行（含前缀的 %d 行）", (int)strlen(want) - 1, want, count(lg, want), count(lg, "读帧缓冲变体缺"));
    free(lg);
    nxgal_prog_release(P2);

    printf("· d 版本 1 的旧二进制照读、没有证明；版本 2 尾段坏 → 二进制坏\n");
    {   uint8_t *b1 = malloc(re + 7); memcpy(b1, bin, re); memcpy(b1 + 4, &(uint32_t){1}, 4); memset(b1 + re, 0xab, 7);
        uint32_t A1 = nxgal_prog_load_binary(b1, (int32_t)re, 1), A2 = nxgal_prog_load_binary(b1, (int32_t)re + 7, 1);
        CHECK(nxgal_prog_status(A1, 1) == 0 && gal_prog_get(A1) && !gal_prog_get(A1)->fbr, "版本 1（无尾段）期望建成且没有证明：%s", nxgal_prog_last_error());
        CHECK(nxgal_prog_status(A2, 1) == 0 && gal_prog_get(A2) && !gal_prog_get(A2)->fbr, "版本 1（记录后另有 7 字节）期望建成且没有证明（照旧不看）");
        CHECK(gal_prog_get(A1) && ask(A1, 128, 0, 1) == NULL, "版本 1 程序：期望不给变体");
        nxgal_prog_release(A1); nxgal_prog_release(A2);
        memcpy(b1 + 4, &(uint32_t){2}, 4);
        uint32_t A3 = nxgal_prog_load_binary(b1, (int32_t)re + 7, 1);
        CHECK(nxgal_prog_status(A3, 1) == 1 && strstr(nxgal_prog_last_error(), "尾段"), "版本 2 尾段坏：期望 Failure 且原因提到尾段，实得 %d（%s）", nxgal_prog_status(A3, 1), nxgal_prog_last_error());
        nxgal_prog_release(A3);
        // 变体映射改成绑定 129（不在证明里）：只在尾段确实是 112 字节时改（没有尾段时那个偏移在缓冲外）
        uint8_t *b4 = malloc(n); memcpy(b4, bin, n);
        if (rt_tl == 112) b4[re + 4 + 64 + 4 + 10 + 4 + 2] = 129;
        uint32_t A4 = nxgal_prog_load_binary(b4, n, 1);
        CHECK(rt_tl == 112 && nxgal_prog_status(A4, 1) == 1, "尾段变体映射不在证明里：期望 Failure");
        nxgal_prog_release(A4); free(b1); free(b4);
    }
    free(bin);
    nxgal_shutdown();
    printf("%s：%d / %d 项通过\n", g_fail ? "失败" : "通过", g_checks - g_fail, g_checks);
    return g_fail ? 1 : 0;
}
GAL_MTL4_ZONE_END
