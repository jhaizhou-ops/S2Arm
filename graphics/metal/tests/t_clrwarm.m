// 清屏管线预热单测（gal_pass.m clr_pipeline / gal_warm_clear，10-22 动森 M2 只差首局一条「管线现建：顶点 clr_vs 片元 -」）：
//   nxgal_warm_internal 预建全部清屏基础管线（附件 -1 与 0–7 × 三种分量类型 × 采样 1 / 4），之后任何着色器清屏首次用到都只特化、不现建。
// 着色器清屏的触发：剪裁矩形没盖满目标（clear_rect 不 covers_all），清屏落成通道内画三角，不折成加载动作。
// 期望（手算）：预热后，① 单采样：4 个颜色附件（RGBA8 / R32Uint / RGBA16F / RGBA8）+ D32 深度，局部剪裁下清第 3 号附件、清第 1 号（整数）、清深度；
//   ② 4 倍采样：RGBA8 + D32 各 4 倍采样，清深度、清第 0 号 —— 两组现建增量都是 0（nxgal_pso_cache_stats 现建计数）。
//   旧代码：只清深度那条不走两级、第 1–7 号附件与 4 倍采样都不预建 → ① 至少 3 条、② 至少 2 条现建。
#import <Metal/Metal.h>
#include "../gal_abi.h"
#include "../gal_internal.h"
#include "../gal_formats.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

GAL_MTL4_ZONE_BEGIN
static int g_fail, g_checks;
#define CHECK(cond, ...) do { g_checks++; if (!(cond)) { g_fail++; printf("  ✗ " __VA_ARGS__); printf("\n"); } } while (0)
static nxgal_tex_info ti(int fmt, int bpp, int samples) { nxgal_tex_info i = {32, 32, 1, 1, samples, 1, 1, bpp, fmt, 0, samples > 1 ? 5 : 1, {2, 3, 4, 5}}; return i; }
static uint64_t misses(void) { uint64_t s[4]; nxgal_pso_cache_stats(s); return s[1]; }
static void partial_scissor(void) { nxgal_rect sc = {0, 0, 16, 16}; nxgal_set_scissors(&sc, 1); nxgal_viewport vp = {0, 0, 32, 32, {0, 2, 4, 6}, 0, 1}; nxgal_set_viewports(&vp, 1); }

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    setenv("NXGAL_BOUNDS_COUNT", "0", 1);
    if (nxgal_init(0)) return 2;
    nxgal_warm_internal();
    float z[4] = {0.25f, 0.5f, 0.75f, 1}, zi[4] = {7, 8, 9, 10};

    printf("· ① 单采样：4 个颜色附件 + 深度，局部剪裁清第 3 号、第 1 号（整数）、深度\n");
    {
        nxgal_tex_info c0 = ti(F_R8G8B8A8Unorm, 4, 1), c1 = ti(F_R32Uint, 4, 1), c2 = ti(F_R16G16B16A16Float, 8, 1), dd = ti(F_D32Float, 4, 1);
        uint32_t C[4] = {nxgal_tex_create(&c0), nxgal_tex_create(&c1), nxgal_tex_create(&c2), nxgal_tex_create(&c0)}, D = nxgal_tex_create(&dd);
        nxgal_set_render_targets(C, 4, D); partial_scissor();
        uint64_t m0 = misses();
        nxgal_clear_color(3, 0, 1, 0xf, z); nxgal_clear_color(1, 0, 1, 0xf, zi); nxgal_clear_ds(0, 1, 0.5f, 1, 0, 0);
        uint8_t rb[32 * 32 * 4]; nxgal_tex_get_data(C[3], 0, 0, rb, sizeof rb);   // 读回 = 提交并等完（清屏真画了）
        uint64_t d = misses() - m0;
        CHECK(d == 0, "① 预热后着色器清屏现建期望 0 条，实得 %llu 条", (unsigned long long)d);
        CHECK(rb[0] == 64 && rb[2] == 191 && rb[(20 * 32 + 20) * 4] == 0, "① 第 3 号附件期望剪裁内 = 清色（64 / 191）、剪裁外 = 0，实得 (0,0) %u / %u、(20,20) %u", rb[0], rb[2], rb[(20 * 32 + 20) * 4]);
        for (int i = 0; i < 4; i++) nxgal_tex_release(C[i]); nxgal_tex_release(D);
    }
    printf("· ② 4 倍采样：RGBA8 + 深度，局部剪裁清深度、清第 0 号\n");
    {
        nxgal_tex_info c0 = ti(F_R8G8B8A8Unorm, 4, 4), dd = ti(F_D32Float, 4, 4);
        uint32_t C = nxgal_tex_create(&c0), D = nxgal_tex_create(&dd);
        nxgal_set_render_targets(&C, 1, D); partial_scissor();
        uint64_t m0 = misses();
        nxgal_clear_ds(0, 1, 0.5f, 1, 0, 0); nxgal_clear_color(0, 0, 1, 0xf, z);
        nxgal_flush();
        uint64_t d = misses() - m0;
        CHECK(d == 0, "② 预热后 4 倍采样着色器清屏现建期望 0 条，实得 %llu 条", (unsigned long long)d);
        nxgal_tex_release(C); nxgal_tex_release(D);
    }
    nxgal_shutdown();
    printf("%s：%d / %d 项通过\n", g_fail ? "失败" : "通过", g_checks - g_fail, g_checks);
    return g_fail ? 1 : 0;
}
GAL_MTL4_ZONE_END
