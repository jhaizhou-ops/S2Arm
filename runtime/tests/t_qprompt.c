// 撑不住就问玩家判定单测（runtime/src/qprompt.c）：喂时间序列，期望按规则手算（基线 10 秒、游戏画面 = 绘制 ≥ 基线 × 3 且非视频 / 过场 / 断档，
//   帧率：连续游戏画面 ≥ 30 秒且最近 30 秒 < 55 帧；满屏：游戏画面里没铺满累计 ≥ 20 秒）
#include "s2a_qprompt.h"
#include <stdio.h>
static int bad;
#define CHECK(c, ...) do { if (!(c)) { printf("✗ " __VA_ARGS__); printf("\n"); bad++; } else { printf("✓ " __VA_ARGS__); printf("\n"); } } while (0)
static const double S = 1e9;
static double T;   // 当前时刻（秒）
static int g_fl = 1, g_wl = 1, g_itv = 1;   // 60 帧此刻生效 / 画面此刻放宽 / 游戏自设交换间隔
// 喂 sec 秒、每帧 ms 毫秒、绘制 d；返回第一次触发的提示种类（0 = 没触发），*at = 触发时刻（秒）
static int feed(double sec, double ms, unsigned d, int video, int cut, int unfit, double *at) {
    int got = 0; for (double end = T + sec; T < end - 1e-9; T += ms / 1000) { int r = s2a_qp_present((uint64_t)(T * S), d, video, cut, unfit, g_fl, g_wl, g_itv); if (r && !got) { got = r; if (at) *at = T; } }
    return got;
}
static void fresh(int f, int w) { g_fl = g_wl = g_itv = 1; s2a_qp_config(f, w); s2a_qp_reset(); T = 100; feed(10.02, 16.667, 20, 0, 0, 0, 0); }   // 开局 10 秒标题页（绘制 20）→ 基线 20
int main(void) {
    double at = 0;
    fresh(1, 1); CHECK(s2a_qp_base() == 20, "基线 = 开局 10 秒绘制中位 20（实 %u）", s2a_qp_base());
    CHECK(feed(60, 16.667, 600, 0, 0, 0, 0) == 0, "局内稳 60 帧 60 秒：不问");
    fresh(1, 1); int r = feed(60, 33.333, 600, 0, 0, 0, &at);
    CHECK(r == S2A_QP_FPS && at - 110.02 > 29.9 && at - 110.02 < 30.1 && s2a_qp_secs() == 30, "局内 30 帧：连续满 30 秒那一刻问帧率、文案秒数 30（实 种类 %d，局内第 %.2f 秒，秒数 %d）", r, at - 110.02, s2a_qp_secs());
    CHECK(feed(60, 33.333, 600, 0, 0, 0, 0) == 0, "同一局问过不再问");
    // 每 5 秒里 4 秒 60 帧 + 1 秒 30 帧 = 270 帧 / 5 秒 = 54 帧/秒 < 55 → 问；9 秒 60 + 1 秒 30 = 570 / 10 = 57 → 不问
    fresh(1, 0); r = 0; for (int i = 0; i < 12 && !r; i++) { r = feed(4, 16.667, 600, 0, 0, 0, 0); if (!r) r = feed(1, 33.333, 600, 0, 0, 0, 0); }
    CHECK(r == S2A_QP_FPS, "每 5 秒落 30 帧 1 秒（均 54 帧）：问帧率（实 %d）", r);
    fresh(1, 0); r = 0; for (int i = 0; i < 6 && !r; i++) { r = feed(9, 16.667, 600, 0, 0, 0, 0); if (!r) r = feed(1, 33.333, 600, 0, 0, 0, 0); }
    CHECK(r == 0, "每 10 秒落 30 帧 1 秒（均 57 帧）：不问（实 %d）", r);
    fresh(1, 1); CHECK(feed(60, 33.333, 600, 0, 1, 0, 0) == 0, "过场标记里 30 帧 60 秒：不问");
    fresh(1, 1); CHECK(feed(60, 33.333, 150, 1, 0, 0, 0) == 0, "在放视频 30 帧 60 秒：不问");
    fresh(1, 1); CHECK(feed(60, 33.333, 40, 0, 0, 0, 0) == 0, "菜单页（绘制 40 < 基线 × 3 = 60）30 帧 60 秒：不问");
    // 每 20 秒断档 2 秒（读盘 / 暂停）：游戏画面从没连续满 30 秒 → 不问
    fresh(1, 0); r = 0; for (int i = 0; i < 5 && !r; i++) { r = feed(20, 33.333, 600, 0, 0, 0, 0); T += 2; }
    CHECK(r == 0, "30 帧但每 20 秒断档 2 秒：不问（实 %d）", r);
    fresh(0, 1); CHECK(feed(60, 33.333, 600, 0, 0, 0, 0) == 0, "帧率提示关着（没 60 帧能力 / 本来 60 帧 / 已问过）：不问");
    // 满屏：局内没铺满累计 20 秒问；只在过场里没铺满不问；分两段 12 + 12 秒累计到 20 秒问
    fresh(0, 1); r = feed(30, 16.667, 600, 0, 0, 1, &at);
    CHECK(r == S2A_QP_FIT && at - 110.02 > 19.9 && at - 110.02 < 20.1 && s2a_qp_secs() == 20, "局内没铺满：累计 20 秒问满屏、文案秒数 20（实 种类 %d，第 %.2f 秒，秒数 %d）", r, at - 110.02, s2a_qp_secs());
    CHECK(!s2a_qp_fit_wanted(), "满屏问过之后：不再采样（实 %d）", s2a_qp_fit_wanted());
    fresh(0, 1); CHECK(!s2a_qp_fit_wanted(), "开局 10 秒标题页：不采样（实 %d）", s2a_qp_fit_wanted());
    feed(1, 16.667, 600, 0, 0, 0, 0); CHECK(s2a_qp_fit_wanted(), "局内游戏画面、放宽着、还能问：采样（实 %d）", s2a_qp_fit_wanted());
    feed(1, 16.667, 30, 0, 0, 0, 0); CHECK(!s2a_qp_fit_wanted(), "菜单页（绘制 30 < 基线 × 3）：不采样（实 %d）", s2a_qp_fit_wanted());
    feed(1, 16.667, 600, 0, 1, 0, 0); CHECK(!s2a_qp_fit_wanted(), "过场：不采样（实 %d）", s2a_qp_fit_wanted());
    g_wl = 0; feed(1, 16.667, 600, 0, 0, 0, 0); CHECK(!s2a_qp_fit_wanted(), "画面没放宽（退回 16:9）：不采样（实 %d）", s2a_qp_fit_wanted()); g_wl = 1;
    fresh(1, 0); feed(1, 16.667, 600, 0, 0, 0, 0); CHECK(!s2a_qp_fit_wanted(), "满屏提示关着（App 记过）：不采样（实 %d）", s2a_qp_fit_wanted());
    fresh(0, 1); CHECK(feed(60, 16.667, 600, 0, 1, 1, 0) == 0, "只在过场里没铺满：不问");
    fresh(0, 1); CHECK(feed(60, 16.667, 30, 0, 0, 1, 0) == 0, "只在菜单页（绘制 30）没铺满：不问");
    fresh(0, 1); r = feed(12, 16.667, 600, 0, 0, 1, 0); if (!r) r = feed(10, 16.667, 600, 0, 0, 0, 0); if (!r) r = feed(12, 16.667, 600, 0, 0, 1, &at);
    CHECK(r == S2A_QP_FIT && at - 132.02 > 7.9 && at - 132.02 < 8.1, "没铺满 12 秒 + 正常 10 秒 + 没铺满：第二段第 8 秒累计到 20 秒问（实 %d，第 %.2f 秒）", r, at - 132.02);
    fresh(1, 0); CHECK(feed(30, 16.667, 600, 0, 0, 1, 0) == 0, "满屏提示关着（本来 16:9 / 没开宽屏）：不问");
    // 运行时生效状态（总指挥 11-02）：60 帧没生效（本来 60 帧 / 没来源 / 关了 / 热降档）的 30 帧不问；中途降档打断连续段；宽屏没生效的没铺满不问
    fresh(1, 1); g_fl = 0; CHECK(feed(60, 33.333, 600, 0, 0, 0, 0) == 0, "60 帧没生效时局内 30 帧 60 秒：不问");
    fresh(1, 0); r = feed(20, 33.333, 600, 0, 0, 0, 0); g_fl = 0; if (!r) r = feed(2, 33.333, 600, 0, 0, 0, 0); g_fl = 1; if (!r) r = feed(29, 33.333, 600, 0, 0, 0, 0);
    CHECK(r == 0, "30 帧 20 秒、热降档 2 秒、再 29 秒：连续段被打断、不满 30 秒，不问（实 %d）", r);
    fresh(0, 1); g_wl = 0; CHECK(feed(60, 16.667, 600, 0, 0, 1, 0) == 0, "宽屏没生效时没铺满 60 秒：不问");
    // 原生 60 帧（总指挥 11-02）：游戏画面帧里游戏自设间隔累计 30 秒都是 1 → 1；见过 ≥ 2 → 0；不够 30 秒 / 只在菜单 → -1
    fresh(0, 0); CHECK(s2a_qp_native60() == -1, "开局 10 秒标题页（不是游戏画面）：未定（实 %d）", s2a_qp_native60());
    feed(29, 16.667, 600, 0, 0, 0, 0); CHECK(s2a_qp_native60() == -1, "局内间隔 1 共 29 秒：未定（实 %d）", s2a_qp_native60());
    feed(2, 16.667, 600, 0, 0, 0, 0); CHECK(s2a_qp_native60() == 1, "局内间隔 1 累计满 30 秒：原生 60 帧（实 %d）", s2a_qp_native60());
    fresh(0, 0); feed(60, 16.667, 40, 0, 0, 0, 0); g_itv = 2; feed(1, 33.333, 600, 0, 0, 0, 0); CHECK(s2a_qp_native60() == 0, "菜单页间隔 1 一分钟不算、局内一出现间隔 2：不是原生 60 帧（实 %d）", s2a_qp_native60());
    fresh(0, 0); g_itv = 2; feed(40, 16.667, 40, 0, 0, 0, 0); g_itv = 1; feed(31, 16.667, 600, 0, 0, 0, 0); CHECK(s2a_qp_native60() == 1, "只在菜单页设间隔 2、局内间隔 1 满 30 秒：原生 60 帧（实 %d）", s2a_qp_native60());
    fresh(0, 0); feed(20, 16.667, 600, 0, 0, 0, 0); g_itv = 2; feed(1, 33.333, 600, 0, 0, 0, 0); g_itv = 1; feed(40, 16.667, 600, 0, 0, 0, 0); CHECK(s2a_qp_native60() == 0, "局内见过间隔 2 之后再 40 秒间隔 1：仍不是（实 %d）", s2a_qp_native60());
    // 按实际帧间隔判（11-02 八方：间隔一直 1、引擎自己限 30）。期望手算：间隔 1、每帧 33.3 ms 局内 40 秒 → 慢帧 40 秒 ≥ 30 秒且 > 0 的十分之一 → 0；
    //   60 帧 31 秒 + 33.3 ms 慢帧 2 秒（偶发长帧）→ 2 × 10 = 20 ≤ 31 → 1；每帧 23 ms（43 帧，忍龙3 局）40 秒 → 0；每帧 19 ms（52 帧）31 秒 → 都算 60 帧 → 1
    fresh(0, 0); feed(40, 33.333, 600, 0, 0, 0, 0); CHECK(s2a_qp_native60() == 0, "间隔 1 但每帧 33.3 ms 局内 40 秒（引擎自己限 30）：不是原生 60 帧（实 %d）", s2a_qp_native60());
    fresh(0, 0); feed(31, 16.667, 600, 0, 0, 0, 0); feed(2, 33.333, 600, 0, 0, 0, 0); CHECK(s2a_qp_native60() == 1, "60 帧 31 秒夹 2 秒长帧：仍是原生 60 帧（实 %d）", s2a_qp_native60());
    fresh(0, 0); feed(40, 23.0, 600, 0, 0, 0, 0); CHECK(s2a_qp_native60() == 0, "间隔 1、每帧 23 ms（43 帧）40 秒：不是（实 %d）", s2a_qp_native60());
    fresh(0, 0); feed(31, 19.0, 600, 0, 0, 0, 0); CHECK(s2a_qp_native60() == 1, "间隔 1、每帧 19 ms（52 帧）31 秒：算原生 60（实 %d）", s2a_qp_native60());
    // 11-05 核心异常算画面不可靠（s2a_qp_unfit_sample）。期望按定义手算：首次读只记基数不算；之后涨了算、不涨不算；判据种类 1–3 算、0 / 4 / 5 / -1 不算
    { int64_t last = -1; int a1 = s2a_qp_unfit_sample(-1, 5, &last), a2 = s2a_qp_unfit_sample(-1, 5, &last), a3 = s2a_qp_unfit_sample(-1, 9, &last), a4 = s2a_qp_unfit_sample(0, 9, &last);
      CHECK(a1 == 0 && a2 == 0 && a3 == 1 && a4 == 0 && last == 9, "核心异常：首读 5 不算 / 不涨不算 / 涨到 9 算 / 再不涨不算（实 %d %d %d %d，记 %lld）", a1, a2, a3, a4, (long long)last);
      int k[7] = { -1, 0, 1, 2, 3, 4, 5 }, got = 0; for (int i = 0; i < 7; i++) got = got * 10 + s2a_qp_unfit_sample(k[i], 9, &last);
      CHECK(got == 11100, "判据种类 -1 0 1 2 3 4 5 在异常不涨时只有 1 / 2 / 3 算（实 %07d）", got);
      // 接进满屏判定：每秒一次「核心异常涨了」持续 20 秒（游戏画面、画面放宽）→ 问满屏，与判据报没铺满同口径
      fresh(0, 1); int64_t e = -1, n = 100; s2a_qp_unfit_sample(-1, n, &e); int r2 = 0; double at2 = 0;
      for (int i = 0; i < 25 && !r2; i++) { int u = s2a_qp_unfit_sample(-1, ++n, &e); r2 = feed(1, 16.667, 600, 0, 0, u, &at2); }
      CHECK(r2 == S2A_QP_FIT, "核心每秒都有新异常 25 秒内：问满屏（实 %d）", r2); }
    printf("%s t_qprompt：%d 处不符\n", bad ? "✗" : "✓", bad); return bad != 0;
}
