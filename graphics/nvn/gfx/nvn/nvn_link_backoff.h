// 显示链路降到低频档（30 / 20 Hz）的退避（link_sync 用；纯状态机，时间由调用方给，单测 graphics/nvn/tests/t_link_backoff.c）。
// 降档要求「同一周期稳 hold 秒」：进低频档后不到 2 秒就因周期表示不了被打回基础档，说明游戏在来回切，hold 翻倍（1→2→4… 封顶 64 秒）；
//   在低频档稳住 60 秒恢复 1 秒。11-04 金刚 Mac 按游戏间隔出帧：间隔 3 稳 1 秒降 20 Hz、一帧间隔 2 立即回 60 Hz，260 秒换档 96 次。
#pragma once
#include <stdint.h>

enum { LB_HOLD0 = 1, LB_HOLD_MAX = 64, LB_FLAP_S = 2, LB_RESET_S = 60 };   // 秒
#define LB_S 1000000000ull
typedef struct { uint64_t since, hold; } link_backoff;   // since：进入当前低频档的时刻（0 = 不在低频档）；hold：降档要求的稳定时长（0 = 初值）

static inline uint64_t lb_hold(const link_backoff *b) { return b->hold ? b->hold : LB_HOLD0 * LB_S; }
// 每帧调用：在低频档已稳住 60 秒，hold 恢复初值
static inline void lb_tick(link_backoff *b, uint64_t now) { if (b->since && now - b->since >= LB_RESET_S * LB_S) b->hold = LB_HOLD0 * LB_S; }
// 当前低频档表示不了本帧周期、被打回基础档：进低频档不到 2 秒算来回切，hold 翻倍
static inline void lb_forced_back(link_backoff *b, uint64_t now) {
    uint64_t h = lb_hold(b);
    if (b->since && now - b->since < LB_FLAP_S * LB_S) b->hold = h * 2 > LB_HOLD_MAX * LB_S ? LB_HOLD_MAX * LB_S : h * 2;
}
// 链路档实际改变时调用：进入低频档记时刻，离开清零
static inline void lb_applied(link_backoff *b, int from, int to, uint64_t now) { if (to >= 3 && from < 3) b->since = now; else if (to < 3) b->since = 0; }
