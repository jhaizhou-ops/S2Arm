// 实体手柄退出游戏（#276，Mac 宿主 macos/front_mac.m 用）：按住 Home 2 秒（没有 Home 的手柄：「+」「-」同时按住 2 秒）弹出确认，
//   确认打开期间游戏失焦、不收手柄输入；按 A 退出（走和 ⌘Q 同一条收尾），按 B 或 Home 取消；30 秒没理会按取消收起。
//   纯逻辑、不碰 GameController / AppKit：放在头里是为了能在宿主上直接单测（runtime/tests/t_home_quit.c）。
//   按键都按「刚按下」算（上一帧没按、这一帧按着），长按 Home 打开确认之后要先松开，这一下不会被当成「再按 Home 取消」。
#ifndef S2A_HOME_QUIT_H
#define S2A_HOME_QUIT_H
#include <stdbool.h>
#include <stdint.h>

#define S2A_HQ_HOLD_NS    2000000000ull    // 按住多久弹确认
#define S2A_HQ_TIMEOUT_NS 30000000000ull   // 确认没人理多久自动收起

typedef enum { S2A_HQ_NONE, S2A_HQ_OPEN, S2A_HQ_QUIT, S2A_HQ_CANCEL } s2a_hq_action;

typedef struct {
    bool open;              // 确认正显示
    uint64_t held_since;    // 触发键按下的时刻（0 = 没按着）
    uint64_t opened_at;
    bool prev_home, prev_a, prev_b;
} s2a_hq_state;

// trigger = Home 按着 或「+」「-」同时按着；home / a / b 是这一帧的原始状态（a / b 按任天堂键位：A 东、B 南）
static inline s2a_hq_action s2a_hq_step(s2a_hq_state *s, uint64_t now, bool trigger, bool home, bool a, bool b) {
    bool home_edge = home && !s->prev_home, a_edge = a && !s->prev_a, b_edge = b && !s->prev_b;
    s->prev_home = home; s->prev_a = a; s->prev_b = b;
    if (s->open) {
        if (a_edge) { s->open = false; s->held_since = 0; return S2A_HQ_QUIT; }
        if (b_edge || home_edge || now - s->opened_at >= S2A_HQ_TIMEOUT_NS) { s->open = false; s->held_since = 0; return S2A_HQ_CANCEL; }
        return S2A_HQ_NONE;
    }
    if (!trigger) { s->held_since = 0; return S2A_HQ_NONE; }
    if (!s->held_since) { s->held_since = now ? now : 1; return S2A_HQ_NONE; }
    if (now - s->held_since >= S2A_HQ_HOLD_NS) { s->open = true; s->opened_at = now; s->held_since = 0; return S2A_HQ_OPEN; }
    return S2A_HQ_NONE;
}
// 鼠标点了确认条上的按钮 / 窗口失焦：外部关掉确认时同步状态
static inline void s2a_hq_close(s2a_hq_state *s) { s->open = false; s->held_since = 0; }
#endif
