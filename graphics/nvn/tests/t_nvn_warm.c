// 管线预热进度的纯逻辑（graphics/nvn/gfx/nvn/nvn_warm.h）：加载页何时交还宿主、速率滑动窗口。纯 C，不要 GPU。期望按规则手算，不跑被测实现推：
//   交还：玩家点「先开始玩」最优先；其次 idle ≥ 卡住阈值；最后总时长 ≥ 上限；阈值 / 上限为 0 不生效
//   速率：每 0.1 秒完成 10 行（100 行/秒），第 3 秒、窗口 2 秒 → 窗口内最早样本 t = 1.0 s、完成 100 → (300 − 100) / 2 = 100；
//         间隔不足 0.1 秒的样本不记；空环 0；窗口里没有样本（只在 0 秒有一个、完成 0，5 秒时完成 50）→ 用它：50 / 5 = 10
#include "nvn_warm.h"
#include <math.h>
#include <stdio.h>
#include <string.h>
static int fails, checks;
#define CHECK(c, ...) do { checks++; if (!(c)) { fails++; printf("✗ "); printf(__VA_ARGS__); putchar('\n'); } } while (0)
#define S(x) ((uint64_t)((x) * 1e9))
int main(void) {
    CHECK(warm_hold_why(S(1), S(30), 1, S(600), S(20)) == WARM_WHY_PLAYER, "玩家点了先开始玩：优先于卡住");
    CHECK(warm_hold_why(S(30), S(20), 0, S(600), S(20)) == WARM_WHY_STALL, "20 秒没进展：交还（卡住）");
    CHECK(warm_hold_why(S(30), S(19.9), 0, S(600), S(20)) == WARM_WHY_NONE, "19.9 秒没进展：继续等");
    CHECK(warm_hold_why(S(600), S(1), 0, S(600), S(20)) == WARM_WHY_LIMIT, "600 秒：交还（上限）");
    CHECK(warm_hold_why(S(5000), S(1), 0, 0, S(20)) == WARM_WHY_NONE, "上限 0：不按总时长交还");
    CHECK(warm_hold_why(S(30), S(5000), 0, S(600), 0) == WARM_WHY_NONE, "卡住阈值 0：不按卡住交还");
    warm_ring r; memset(&r, 0, sizeof r);
    CHECK(warm_ring_rate(&r, S(1), 10, WARM_RATE_WIN_NS) == 0, "空环：速率 0");
    for (int k = 0; k <= 30; k++) warm_ring_add(&r, S(k * 0.1), 10 * k);
    warm_ring_add(&r, S(3.05), 999);   // 距上个样本 0.05 秒：不记
    double v = warm_ring_rate(&r, S(3.0), 300, WARM_RATE_WIN_NS);
    CHECK(fabs(v - 100) < 1e-6, "每 0.1 秒 10 行、第 3 秒 2 秒窗口：速率 %.6f（期望 100）", v);
    CHECK(r.n == 31 && r.d[(r.h + WARM_RING_N - 1) % WARM_RING_N] == 300, "间隔不足 0.1 秒的样本不记：31 个样本、最新完成 300（实得 %d 个）", r.n);
    for (int k = 31; k <= 40; k++) warm_ring_add(&r, S(k * 0.1), 10 * k);
    CHECK(r.n == WARM_RING_N && r.t[r.h] == S(0.9), "环满只留最近 %d 个：最老的是 0.9 秒那个", WARM_RING_N);
    warm_ring q; memset(&q, 0, sizeof q); warm_ring_add(&q, S(0), 0);
    v = warm_ring_rate(&q, S(5), 50, WARM_RATE_WIN_NS);
    CHECK(fabs(v - 10) < 1e-6, "窗口里没有样本：用窗口之前最新的（0 秒、0 行）→ %.6f（期望 10）", v);
    printf("%s t_nvn_warm：%d 项，%d 处不符\n", fails ? "✗" : "✓", checks, fails);
    return fails != 0;
}
