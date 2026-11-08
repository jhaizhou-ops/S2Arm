// 线程时间约束（实时）声明（10-24，缺省关：NXGAL_RT=1 开；测试机2 同包 A/B 帧时 / 慢帧 / 能耗达标再翻）
// 借鉴：上游参考实现（MIT，dm/gfx/nvn/hle_nvn.c set_time_constraint_comp / rt_comp_tick；10-24 取，文件 sha256 前 16 位 06b1a4bbe6451413）。只借做法，代码自写。
//   做法：给每帧都要按时做完的线程声明 THREAD_TIME_CONSTRAINT_POLICY（周期 = 帧周期、约束 = 帧周期、计算量 = 这条线程每帧实际要的 CPU 时间），
//   系统调度器和性能控制器由此知道帧截止时间与工作量。
//   他们实测的坑照搬：声明的计算量小于实际，线程会被系统降级、每超一次卡 30–60 ms。所以计算量不能写死，按本线程每帧 CPU 时间自适应：
//   每 120 帧取 max(1.25 × p90, 1.1 × 峰值)，封顶 0.9 × 周期、下限 1 ms；与已声明值差超 15% 才重新声明。
// 我方用在 Metal 编码线程（S2A.GPU，nxgal_present 每帧调一次，gal_present.m）：它是每帧出图路径上的关键线程。
//   GPU 模拟线程 / 游戏主线程是否也声明，等这一条的 A/B 读数出来再定。
#import "gal_internal.h"
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/thread_policy.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static int dcmp(const void *a, const void *b) { double x = *(const double *)a, y = *(const double *)b; return x < y ? -1 : x > y; }

// 纯函数：120 帧每帧 CPU 毫秒 → 该声明的计算量（毫秒）
double gal_rt_comp_from_window(const double win[GAL_RT_WIN], double period_ms) {
    double v[GAL_RT_WIN]; memcpy(v, win, sizeof v); qsort(v, GAL_RT_WIN, sizeof *v, dcmp);
    double p90 = v[GAL_RT_WIN * 9 / 10 - 1], peak = v[GAL_RT_WIN - 1];
    double c = p90 * 1.25 > peak * 1.1 ? p90 * 1.25 : peak * 1.1, cap = period_ms * 0.9;
    if (c > cap) c = cap;
    if (c < 1) c = 1;
    return c;
}

int gal_rt_on(void) { static int v = -1; if (v < 0) { const char *e = getenv("NXGAL_RT"); v = e && !strcmp(e, "1"); } return v; }

static int declare(double period_ms, double comp_ms) {
    static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb);
    uint64_t pn = (uint64_t)(period_ms * 1e6), cn = (uint64_t)(comp_ms * 1e6);
    thread_time_constraint_policy_data_t p = {
        .period = (uint32_t)(pn * tb.denom / tb.numer), .computation = (uint32_t)(cn * tb.denom / tb.numer),
        .constraint = (uint32_t)(pn * tb.denom / tb.numer), .preemptible = 1};
    kern_return_t kr = thread_policy_set(pthread_mach_thread_np(pthread_self()), THREAD_TIME_CONSTRAINT_POLICY, (thread_policy_t)&p, THREAD_TIME_CONSTRAINT_POLICY_COUNT);
    char nm[64] = ""; pthread_getname_np(pthread_self(), nm, sizeof nm);
    GLOG("实时声明：线程 %s 周期 %.2f ms、计算量 %.2f ms %s", nm[0] ? nm : "?", period_ms, comp_ms, kr == KERN_SUCCESS ? "已设" : "设不上");
    return kr == KERN_SUCCESS;
}

// 本线程状态（每条调它的线程各一份）
static __thread struct { uint64_t last; double win[GAL_RT_WIN]; int n; double comp, period; int low_n; } t_rt;
gal_rt_stat_t g_rt_stat;

// 每帧调一次（调用线程即被声明的线程）：period_ms = 这一帧的帧周期（0 = 不知道，跳过）
void gal_rt_tick(double period_ms) {
    if (!gal_rt_on() || period_ms <= 0) return;
    uint64_t c = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID);
    // 周期变了（30 ↔ 60 帧）：按已声明的计算量（第一次 2 ms 起步）立即重声明，不等下一个窗口
    if (t_rt.period != period_ms) {
        double comp = t_rt.comp > 0 ? t_rt.comp : 2.0; if (comp > period_ms * 0.9) comp = period_ms * 0.9;
        if (declare(period_ms, comp)) { t_rt.comp = comp; g_rt_stat.declares++; }
        t_rt.period = period_ms; t_rt.last = c; t_rt.n = 0; return;
    }
    if (!t_rt.last) { t_rt.last = c; return; }
    t_rt.win[t_rt.n++] = (double)(c - t_rt.last) / 1e6; t_rt.last = c;
    if (t_rt.n < GAL_RT_WIN) return;
    t_rt.n = 0;
    // 10-24 马车8 真机 A/B：计算量在 7.9 ~ 15.0 ms 间来回跳（15.0 = 封顶，加载尖峰把峰值顶满）。改两条：
    //   ① 窗口峰值超过封顶（0.9 × 周期）= 这窗有加载尖峰、本线程本来就超时，声明值不动（顶满的声明等于没告诉调度器截止时间）；
    //   ② 滞后：调高立即（少声明会被降级卡 30–60 ms），调低要连续 3 个窗口都低于 0.85 × 现值才降
    double peak = 0; for (int i = 0; i < GAL_RT_WIN; i++) if (t_rt.win[i] > peak) peak = t_rt.win[i];
    if (peak > period_ms * 0.9) { g_rt_stat.spike_windows++; t_rt.low_n = 0; g_rt_stat.last_comp_ms = t_rt.comp; return; }
    double comp = gal_rt_comp_from_window(t_rt.win, period_ms);
    if (comp > t_rt.comp * 1.15) { t_rt.low_n = 0; if (declare(period_ms, comp)) { t_rt.comp = comp; g_rt_stat.declares++; } }
    else if (comp < t_rt.comp * 0.85) { if (++t_rt.low_n >= 3) { t_rt.low_n = 0; if (declare(period_ms, comp)) { t_rt.comp = comp; g_rt_stat.declares++; } } }
    else t_rt.low_n = 0;
    g_rt_stat.last_comp_ms = t_rt.comp;
}
