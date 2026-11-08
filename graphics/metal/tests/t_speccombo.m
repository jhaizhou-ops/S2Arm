// 通用特化预热单测（gal_state.m gal_warm_spec_combos，10-22 动森首遇特化慢根治）：nxgal_warm_internal 起预热，在编译器线程上把
//   「可渲染颜色格式 × 写掩码 1–15（含全写）」与九款录像的 70 种混合 / 部分掩码组合在清屏基础管线上各特化一次。
// 期望（手算）：起的条数 ≥ 70 + 14（录像组合 70 种 + 至少一种格式的 14 种掩码），30 秒内全部完成，失败 0
//   （失败 = 格式 / 输出类型 / 描述填错，例如整数格式配了浮点输出的清屏片元）
// 运行时收组合（10-22 动森复发：混合组合录像没收全）：② 载入 2 条的组合表 → 起数 +2、失败 0；
// ① 之前：⓪ 登记着色器包时（内部预建之前）载入 1 条的组合表 → 现建计数 +0（清屏基础管线按内部预建记；10-22 九款冷启动首局格因此全红的反证）
//   ③ 只有顶点阶段的程序（tests/t_fbr_vsp）画进 RG16F、写掩码只 R → 记下「特化组合」1 行；同组合换一张目标再画 → 不重复记（+0）
#import <Metal/Metal.h>
#include "../gal_abi.h"
#include "../gal_internal.h"
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <libgen.h>
#include "../gal_formats.h"

GAL_MTL4_ZONE_BEGIN
static int g_fail, g_checks;
#define CHECK(cond, ...) do { g_checks++; if (!(cond)) { g_fail++; printf("  ✗ " __VA_ARGS__); printf("\n"); } } while (0)
static uint8_t *load(const char *dir, const char *name, uint32_t *len) {
    char p[1200]; snprintf(p, sizeof p, "%s/%s.spv", dir, name);
    FILE *f = fopen(p, "rb"); if (!f) { printf("读不了 %s\n", p); exit(2); }
    fseek(f, 0, SEEK_END); long l = ftell(f); fseek(f, 0, SEEK_SET);
    uint8_t *b = malloc((size_t)l); if (fread(b, 1, (size_t)l, f) != (size_t)l) exit(2);
    fclose(f); *len = (uint32_t)l; return b;
}
static void wait_combo(uint64_t s[4]) { for (int i = 0; i < 3000; i++) { gal_spec_combo_stats(s); if (s[0] != UINT64_MAX && s[1] + s[2] >= s[0]) return; usleep(10000); } }
static void draw_rg16f_r(uint32_t prog) {
    nxgal_tex_info ci = {32, 32, 1, 1, 1, 1, 1, 4, F_R16G16Float, 0, 1, {2, 3, 4, 5}}; uint32_t A = nxgal_tex_create(&ci);
    nxgal_set_render_targets(&A, 1, 0);
    nxgal_blend b = {0, {0, 0, 0, 0}, 1, 2, 1, 1, 2, 1}; for (int i = 0; i < 8; i++) nxgal_set_blend(i, &b);
    nxgal_depth_test d = {0, 0, 8}; nxgal_set_depth_test(&d);
    nxgal_viewport vp = {0, 0, 32, 32, {0, 2, 4, 6}, 0, 1}; nxgal_set_viewports(&vp, 1); nxgal_rect sc = {0, 0, 32, 32}; nxgal_set_scissors(&sc, 1);
    uint32_t m[8] = {1, 0xf, 0xf, 0xf, 0xf, 0xf, 0xf, 0xf}; nxgal_set_color_masks(m, 8);
    float c[4] = {1, 1, 1, 1}; uint32_t u = nxgal_buf_create(16, 0); nxgal_buf_set_data(u, 0, c, 16); nxgal_buf_assign a0 = {0, {u, 0, 16, 0}}; nxgal_set_uniform_buffers(&a0, 1);
    float v[12] = {-1, -1, 0.5f, 1, -1, 0.5f, 1, 1, 0.5f, -1, 1, 0.5f}; uint32_t vb = nxgal_buf_create(48, 0); nxgal_buf_set_data(vb, 0, v, 48);
    nxgal_vbuf vbd = {{vb, 0, 48, 0}, 12, 0}; nxgal_set_vertex_buffers(&vbd, 1); nxgal_vattr at = {0, 0, 0, 33}; nxgal_set_vertex_attribs(&at, 1); nxgal_set_topology(7);
    nxgal_set_program(prog); nxgal_draw(4, 1, 0, 0);
    static uint8_t rb[32 * 32 * 4]; nxgal_tex_get_data(A, 0, 0, rb, sizeof rb); nxgal_tex_release(A);
}
int main(int argc, char **argv) {
    (void)argc; char exe[1024], dir[1100]; snprintf(exe, sizeof exe, "%s", argv[0]); snprintf(dir, sizeof dir, "%s/t_fbr_in", dirname(exe));
    setvbuf(stdout, NULL, _IONBF, 0);
    if (nxgal_init(0)) return 2;
    if (!gal_pso_can_specialize()) { printf("跳过：本机后端没有管线特化（Metal 3）\n"); nxgal_shutdown(); return 0; }
    { char path[] = "/tmp/t_speccombo0_XXXXXX"; int fd = mkstemp(path); FILE *f = fdopen(fd, "w");
      fprintf(f, "v1 %lu 0 0 0 0 0 0 0 0 1\n", (unsigned long)MTLPixelFormatR8Unorm); fclose(f);
      uint64_t a[4], b[4]; nxgal_pso_cache_stats(a); int n = gal_spec_combo_load(path); unlink(path); nxgal_pso_cache_stats(b);
      printf("· ⓪ 内部预建之前载入组合表：现建 +%llu（期望 0）\n", (unsigned long long)(b[1] - a[1]));
      CHECK(n == 1 && b[1] == a[1], "内部预建之前载入组合表期望载入 1 条、现建 +0，实得 %d 条、现建 +%llu", n, (unsigned long long)(b[1] - a[1])); }
    // 预热只走渲染器自己的组合，不许触发「游戏真实管线」才该有的报红（10-24 RGB9E5 × 部分写掩码：九款正式局各 1 行红）：预热期间 stderr 收进临时文件数
    char elog[] = "/tmp/t_speccombo_err_XXXXXX"; int efd = mkstemp(elog), esave = dup(2); fflush(stderr); dup2(efd, 2);
    nxgal_warm_internal();
    uint64_t s[4] = {0}; for (int i = 0; i < 3000; i++) { gal_spec_combo_stats(s); if (s[1] + s[2] >= s[0]) break; usleep(10000); }
    fflush(stderr); dup2(esave, 2); close(esave);
    { FILE *f = fopen(elog, "r"); char ln[1024]; int red9 = 0, warmln = 0;
      while (f && fgets(ln, sizeof ln, f)) { if (strstr(ln, "RGB9E5Float，部分通道写掩码")) red9++; if (strstr(ln, "通用特化预热：起")) warmln++; }
      if (f) fclose(f); close(efd); unlink(elog);
      printf("· 预热期间报红「RGB9E5 部分写掩码」%d 行（期望 0；正对照「通用特化预热：起」%d 行，期望 1）\n", red9, warmln);
      CHECK(warmln == 1, "正对照：预热期间 stderr 期望收到「通用特化预热：起」1 行（证明收得到），实得 %d", warmln);
      CHECK(red9 == 0, "预热期望不触发 RGB9E5 部分写掩码报红，实得 %d 行", red9); }
    printf("· 通用特化预热：起 %llu、完成 %llu、失败 %llu\n", (unsigned long long)s[0], (unsigned long long)s[1], (unsigned long long)s[2]);
    CHECK(s[0] >= 70 + 14, "起的条数期望 ≥ 84（录像组合 70 + 至少一种格式 × 14 种掩码），实得 %llu", (unsigned long long)s[0]);
    CHECK(s[1] + s[2] == s[0], "30 秒内期望全部完成，实得完成 %llu + 失败 %llu / 起 %llu", (unsigned long long)s[1], (unsigned long long)s[2], (unsigned long long)s[0]);
    CHECK(s[2] == 0, "失败期望 0，实得 %llu", (unsigned long long)s[2]);
    // 预热状态（慢特化诊断用）：RG16F 只写 R 不混合在网格里 → 成功（2）；随手挑一个混合组合（RGBA8 加法 DstAlpha / BlendColor）不在表 → 0
    { MTL4RenderPipelineDescriptor *d = [MTL4RenderPipelineDescriptor new]; MTL4RenderPipelineColorAttachmentDescriptor *c = d.colorAttachments[0];
      c.pixelFormat = MTLPixelFormatRG16Float; c.writeMask = MTLColorWriteMaskRed; c.blendingState = MTL4BlendStateDisabled;
      int a = gal_spec_combo_status(c);
      c.pixelFormat = MTLPixelFormatRGBA8Unorm; c.writeMask = MTLColorWriteMaskAll; c.blendingState = MTL4BlendStateEnabled;
      c.rgbBlendOperation = c.alphaBlendOperation = MTLBlendOperationAdd; c.sourceRGBBlendFactor = MTLBlendFactorDestinationAlpha; c.destinationRGBBlendFactor = MTLBlendFactorBlendColor;
      c.sourceAlphaBlendFactor = MTLBlendFactorBlendAlpha; c.destinationAlphaBlendFactor = MTLBlendFactorOneMinusBlendAlpha;
      int b = gal_spec_combo_status(c);
      CHECK(a == 2 && b == 0, "预热状态期望 RG16F 只 R = 2（成功）、不在表的混合组合 = 0，实得 %d、%d", a, b);
      // 全写不混合也在网格里（10-23 塞尔达拷贝 RG32Float 全写 22.8 ms、怪猎清屏 RGB10A2 全写 2.7 ms，都标「预热不在表」）→ 成功（2）
      c.blendingState = MTL4BlendStateDisabled; c.writeMask = MTLColorWriteMaskAll;
      c.pixelFormat = MTLPixelFormatRG32Float; int f1 = gal_spec_combo_status(c);
      c.pixelFormat = MTLPixelFormatRGB10A2Unorm; int f2 = gal_spec_combo_status(c);
      CHECK(f1 == 2 && f2 == 2, "全写不混合期望 RG32Float = 2、RGB10A2Unorm = 2（成功），实得 %d、%d", f1, f2); }

    printf("· ② 载入 2 条的组合表（RG32F 开混合 + RGBA16 只写 G）：起数 +2、失败 0\n");
    { char path[] = "/tmp/t_speccombo_XXXXXX"; int fd = mkstemp(path); FILE *f = fdopen(fd, "w");
      fprintf(f, "# 单测组合表\nv1 %lu 0 1 1 5 6 1 2 2 15\nv1 %lu 0 0 0 0 0 0 0 0 2\n", (unsigned long)MTLPixelFormatRG32Float, (unsigned long)MTLPixelFormatRGBA16Unorm); fclose(f);
      uint64_t a[4]; gal_spec_combo_stats(a); int n = gal_spec_combo_load(path); unlink(path);
      uint64_t b[4]; wait_combo(b);
      CHECK(n == 2 && b[0] - a[0] == 2 && b[2] == a[2], "组合表期望载入 2 条、起 +2、失败 +0，实得 %d 条、起 +%llu、失败 +%llu", n, (unsigned long long)(b[0] - a[0]), (unsigned long long)(b[2] - a[2])); }

    printf("· ③ 运行时特化 RG16F 只写 R：记「特化组合」1 行；同组合再画不重复记\n");
    { uint32_t vl; uint8_t *v = load(dir, "vsp", &vl); nxgal_shader sh[1] = {{v, vl, 1}};
      uint32_t P = nxgal_prog_create(sh, 1, NULL, 0, 0xff); free(v);
      int st = 2; for (int i = 0; i < 500 && P && (st = nxgal_prog_status(P, 0)) == 2; i++) usleep(10000);
      uint64_t a[4]; gal_spec_combo_stats(a); draw_rg16f_r(P); uint64_t b[4]; gal_spec_combo_stats(b); draw_rg16f_r(P); uint64_t c[4]; gal_spec_combo_stats(c);
      CHECK(P && st == 0 && b[3] - a[3] == 1 && c[3] == b[3], "期望记 1 行、再画 +0，实得 +%llu、+%llu（程序状态 %d）", (unsigned long long)(b[3] - a[3]), (unsigned long long)(c[3] - b[3]), st); }
    nxgal_shutdown();
    printf("%s：%d / %d 项通过\n", g_fail ? "失败" : "通过", g_checks - g_fail, g_checks);
    return g_fail ? 1 : 0;
}
GAL_MTL4_ZONE_END
