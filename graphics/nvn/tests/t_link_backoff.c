// 低频链路档降档退避（graphics/nvn/gfx/nvn/nvn_link_backoff.h）：时间由用例给，期望值按规则手算，不跑 link_sync。
// ① 初值 1 秒 ② 进低频档 0.5 秒被打回 → 2 秒，再来回切 → 4、8、16、32、64 封顶 ③ 低频档待 2.5 秒才被打回（正常换档）→ 不翻倍、1.9 秒 → 翻倍
// ④ 低频档稳住 60 秒 → 恢复 1 秒；59.9 秒时不恢复 ⑤ 不在低频档时被「打回」（没有 since）不翻倍
// ⑥ 金刚形态逐帧推演：每 1.45 秒间隔 3 + 1 帧间隔 2，按 link_sync 的「稳 hold 秒才降档」规则，60 秒内降档次数 = 1（不退避时 ≈ 每 1.5 秒一次）
#include <stdio.h>
#include "nvn_link_backoff.h"

static int n, bad;
#define CHECK(c, ...) do { n++; if (!(c)) { bad++; printf("没过 "); printf(__VA_ARGS__); printf("\n"); } } while (0)
static const uint64_t S = LB_S;

int main(void) {
    link_backoff b = {0};
    CHECK(lb_hold(&b) == 1 * S, "① 初值 hold %llu", (unsigned long long)lb_hold(&b));
    // ②
    uint64_t t = 100 * S; lb_applied(&b, 1, 4, t); lb_forced_back(&b, t + S / 2); lb_applied(&b, 4, 1, t + S / 2);
    CHECK(lb_hold(&b) == 2 * S, "② 0.5 秒被打回 hold %llu，期望 2 秒", (unsigned long long)(lb_hold(&b) / S));
    uint64_t want[] = {4, 8, 16, 32, 64, 64};
    for (int i = 0; i < 6; i++) { t += 10 * S; lb_applied(&b, 1, 3, t); lb_forced_back(&b, t + S); lb_applied(&b, 3, 1, t + S);
        CHECK(lb_hold(&b) == want[i] * S, "② 第 %d 次来回切 hold %llu，期望 %llu", i + 2, (unsigned long long)(lb_hold(&b) / S), (unsigned long long)want[i]); }
    // ③ 正常换档不算来回切：低频档待 2.5 秒（单测动态阶段 0：间隔 2 稳 1 秒降 30 Hz、3.6 秒时转间隔 3）被打回 → 不翻倍；1.9 秒 → 翻倍
    link_backoff c = {0}; lb_applied(&c, 1, 3, 1 * S); lb_forced_back(&c, 1 * S + 2500000000ull);
    CHECK(lb_hold(&c) == 1 * S, "③ 2.5 秒后被打回 hold %llu，期望 1 秒", (unsigned long long)(lb_hold(&c) / S));
    link_backoff c2 = {0}; lb_applied(&c2, 1, 3, 1 * S); lb_forced_back(&c2, 1 * S + 1900000000ull);
    CHECK(lb_hold(&c2) == 2 * S, "③ 1.9 秒被打回 hold %llu，期望 2 秒", (unsigned long long)(lb_hold(&c2) / S));
    // ④
    link_backoff d = {0, 16 * S}; lb_applied(&d, 1, 3, 10 * S);
    lb_tick(&d, 10 * S + 59900000000ull); CHECK(lb_hold(&d) == 16 * S, "④ 59.9 秒不恢复 hold %llu", (unsigned long long)(lb_hold(&d) / S));
    lb_tick(&d, 70 * S); CHECK(lb_hold(&d) == 1 * S, "④ 60 秒恢复 hold %llu，期望 1 秒", (unsigned long long)(lb_hold(&d) / S));
    // ⑤
    link_backoff e = {0}; lb_forced_back(&e, 5 * S); CHECK(lb_hold(&e) == 1 * S, "⑤ 不在低频档 hold %llu", (unsigned long long)(lb_hold(&e) / S));
    // ⑥ 逐帧推演：周期 50 ms（间隔 3）29 帧 + 33.3 ms（间隔 2）1 帧；降档条件 = 同一周期已稳 hold；低频档 20 Hz 遇 33.3 ms 立即回基础档
    link_backoff f = {0}; int mode = 1, drops = 0; uint64_t now = 0, stable_since = 0, prev = 0;
    for (int fr = 0; now < 60 * S; fr++) {
        uint64_t period = fr % 30 == 29 ? 33333333ull : 50000000ull;
        if (period != prev) { stable_since = now; prev = period; }
        lb_tick(&f, now);
        if (mode == 4 && period != 50000000ull) { lb_forced_back(&f, now); lb_applied(&f, 4, 1, now); mode = 1; }
        else if (mode == 1 && period == 50000000ull && now - stable_since >= lb_hold(&f)) { lb_applied(&f, 1, 4, now); mode = 4; drops++; }
        now += period;
    }
    CHECK(drops == 1, "⑥ 金刚形态 60 秒降档 %d 次，期望 1", drops);
    // ⑥ 反证：持续间隔 3 时第一秒后就降 20 Hz 且一直不被打回
    link_backoff g = {0}; int down_at = -1; now = 0;
    for (int fr = 0; fr < 100; fr++, now += 50000000ull) if (down_at < 0 && now >= lb_hold(&g)) { lb_applied(&g, 1, 4, now); down_at = fr; }
    CHECK(down_at == 20, "⑥ 持续间隔 3 第 %d 帧降 20 Hz，期望第 20 帧（1 秒）", down_at);
    printf("%s t_link_backoff：%d 项，没过 %d\n", bad ? "✗" : "✓", n, bad);
    return bad != 0;
}
