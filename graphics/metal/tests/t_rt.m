// 线程时间约束（实时）声明单测（gal_rt.m，10-24）。期望（手算，不跑被测实现推）：
//   ① 纯函数：119 帧 2.0 ms + 1 帧 4.4 ms（上游注释里黑暗之魂的实例），周期 16.67 ms → max(1.25 × 2.0, 1.1 × 4.4) = 4.84
//   ② 封顶：120 帧都 30 ms、周期 33.33 ms → 0.9 × 33.33 = 30.0
//   ③ 下限：120 帧都 0.1 ms → 1.0
//   ④ 缺省关（NXGAL_RT 未设）：tick 不声明
//   ⑥ 尖峰窗口（有 1 帧超封顶）不重声明；⑦ 调低要连续 3 个低窗口（10-24 马车8 真机计算量 7.9 ~ 15.0 来回跳）
//   ⑤ 开（NXGAL_RT=1）：第一次 tick 按 2 ms 起步声明；之后每帧烧约 5 ms CPU、跑满 120 帧 → 按窗口重声明，计算量落在 [5.5, 9] ms
#import <Foundation/Foundation.h>
#include "../gal_internal.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static int g_fail, g_checks;
#define CHECK(cond, ...) do { g_checks++; if (!(cond)) { g_fail++; printf("  ✗ " __VA_ARGS__); printf("\n"); } else { printf("  ✓ " __VA_ARGS__); printf("\n"); } } while (0)
static void burn_ms(double ms) { uint64_t t0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID); volatile double x = 0; while (clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - t0 < (uint64_t)(ms * 1e6)) x += 1; }

static int run_on(void) {   // ⑤：开关是进程级缓存，所以在子进程里带 NXGAL_RT=1 跑
    gal_rt_tick(16.67);
    int d1 = (int)g_rt_stat.declares;
    for (int f = 0; f <= GAL_RT_WIN; f++) { burn_ms(5.0); gal_rt_tick(16.67); }
    double c = g_rt_stat.last_comp_ms;
    CHECK(d1 == 1, "⑤ 第一次 tick 起步声明 1 次，实得 %d", d1);
    CHECK(g_rt_stat.declares == 2 && c >= 5.5 && c <= 9.0, "⑤ 每帧约 5 ms 跑满 120 帧后重声明：声明 %llu 次（期望 2）、计算量 %.2f ms（期望 5.5–9）", (unsigned long long)g_rt_stat.declares, c);
    // ⑥ 尖峰窗口：120 帧里有 1 帧烧 16 ms（> 封顶 0.9 × 16.67 = 15.0），其余 5 ms → 声明不动、记尖峰窗口 1
    uint64_t d0 = g_rt_stat.declares; double c0 = g_rt_stat.last_comp_ms;
    for (int f = 0; f < GAL_RT_WIN; f++) { burn_ms(f == 60 ? 16.0 : 5.0); gal_rt_tick(16.67); }
    CHECK(g_rt_stat.declares == d0 && g_rt_stat.spike_windows == 1 && g_rt_stat.last_comp_ms == c0, "⑥ 尖峰窗口不重声明：声明 %llu → %llu（期望不变）、尖峰窗口 %llu（期望 1）、计算量 %.2f → %.2f",
          (unsigned long long)d0, (unsigned long long)g_rt_stat.declares, (unsigned long long)g_rt_stat.spike_windows, c0, g_rt_stat.last_comp_ms);
    // ⑦ 调低滞后：之后每帧 1 ms。窗口边界比循环差 1 帧（⑤ 起步那次 tick 不进窗口、⑤ 跑了 121 次），所以 ⑦ 第 1 个窗口还含 ⑥ 最后 1 帧 5 ms：
    //   该窗口计算量 = max(1.25 × p90 ≈ 1.25, 1.1 × 5) ≈ 5.5 ≥ 0.85 × 6.25 = 5.31 → 不算低、低窗口计数清零；第 2、3 个窗口低（计 1、2）；第 4 个窗口计到 3 才降到约 1.3 ms
    for (int w = 1; w <= 4; w++) {
        uint64_t dd = g_rt_stat.declares;
        for (int f = 0; f < GAL_RT_WIN; f++) { burn_ms(1.0); gal_rt_tick(16.67); }
        if (w < 4) CHECK(g_rt_stat.declares == dd, "⑦ 第 %d 个低窗口不降（声明 %llu → %llu）", w, (unsigned long long)dd, (unsigned long long)g_rt_stat.declares);
        else CHECK(g_rt_stat.declares == dd + 1 && g_rt_stat.last_comp_ms < 2.5, "⑦ 第 4 个窗口（第 3 个连续低窗口）才降：声明 +%llu（期望 1）、计算量 %.2f ms（期望 < 2.5）", (unsigned long long)(g_rt_stat.declares - dd), g_rt_stat.last_comp_ms);
    }
    return g_fail ? 1 : 0;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    if (argc > 1 && !strcmp(argv[1], "--on")) return run_on();
    double w[GAL_RT_WIN];
    for (int i = 0; i < GAL_RT_WIN; i++) w[i] = 2.0; w[37] = 4.4;
    double c = gal_rt_comp_from_window(w, 16.67); CHECK(fabs(c - 4.84) < 1e-9, "① 2.0 ms × 119 + 4.4 ms × 1 → 4.84，实得 %.4f", c);
    for (int i = 0; i < GAL_RT_WIN; i++) w[i] = 30;
    c = gal_rt_comp_from_window(w, 33.33); CHECK(fabs(c - 29.997) < 1e-9, "② 封顶 0.9 × 33.33 = 29.997，实得 %.4f", c);
    for (int i = 0; i < GAL_RT_WIN; i++) w[i] = 0.1;
    c = gal_rt_comp_from_window(w, 16.67); CHECK(fabs(c - 1.0) < 1e-9, "③ 下限 1.0，实得 %.4f", c);
    unsetenv("NXGAL_RT");
    gal_rt_tick(16.67); CHECK(g_rt_stat.declares == 0, "④ 缺省关：不声明（声明 %llu 次）", (unsigned long long)g_rt_stat.declares);
    char cmd[2048]; snprintf(cmd, sizeof cmd, "NXGAL_RT=1 '%s' --on", argv[0]);
    int rc = system(cmd); CHECK(rc == 0, "⑤ 子进程（NXGAL_RT=1）通过（rc %d）", rc);
    printf("%s：%d / %d 项通过\n", g_fail ? "失败" : "通过", g_checks - g_fail, g_checks);
    return g_fail ? 1 : 0;
}
