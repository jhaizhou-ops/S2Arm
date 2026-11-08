// 系统手柄震动（GCDeviceHaptics / CHHapticEngine）失败之后的退避与判死——纯逻辑，不含 CoreHaptics /
//   GameController 依赖，放在头里是为了能在 Mac 宿主上单测（runtime/tests/t_haptic_retry.c）。
//
// 为什么要有这个头：真机日志（iPhone 15 Pro / iOS 27.0.1 / LiveContainer 里的包）里
//   「【红】系统手柄震动：创建播放器失败 Couldn't communicate with a helper application.」
//   在一局 35 分钟里出现 61,341 次，占整份 host.log 71,152 行的 86%，且整局一次都没播放成功过。
//   原因是旧实现失败即 system_reset_on_queue() 把 engine 与 player 一起清掉，下一个震动帧
//   （游戏每秒提交约 29 次）又从「建引擎 → 起引擎 → 建播放器」重来一遍：三次 XPC 往返、三次日志，
//   全在 g_system_haptics_queue 这条串行队列上。抖动本身不是缺陷，把抖动放大成每帧一次才是。
//
// 判据：这个错误是环境性的（CoreHaptics 连不上系统的 haptic helper），重建引擎不会让它变好。
//   所以连续失败 S2A_HP_MAX_FAILS 次就判死，本设备本局不再尝试；换手柄（system_select_device）
//   时重新发一张牌——那之后再失败也只再报一行。
#ifndef S2A_HAPTIC_RETRY_H
#define S2A_HAPTIC_RETRY_H

#include <stdbool.h>
#include <stdint.h>

// 连续失败多少次判死。3 次足够区分「开机瞬间抖动」（前两次会自愈）与「这个环境根本连不上」。
#define S2A_HP_MAX_FAILS 3
// 第 n 次失败后的退避：首次 1000 ms（等 helper 起来），之后 4000 ms。判死后不再退避（直接不试）。
#define S2A_HP_BACKOFF_MS(fails) ((fails) <= 1 ? 1000u : 4000u)

typedef struct {
    int fails;             // 连续失败次数（成功一次即清零）
    bool disabled;         // 已判死：本设备本局不再尝试
    bool reported;         // 已报过第一行红（之后只累计，不再逐次刷屏）
    bool diagnosed;        // 已打过一次引擎 / locality 诊断行
    uint64_t retry_at_ns;  // CLOCK_UPTIME_RAW 纳秒；早于此刻不重试。0 = 没有退避
} s2a_hp_state;

typedef enum {
    S2A_HP_TRY = 0,   // 允许这次尝试
    S2A_HP_SKIP,      // 退避期内或已判死：直接返回，一个 CoreHaptics 调用都不碰
} s2a_hp_action;

static inline s2a_hp_action s2a_hp_should_try(const s2a_hp_state *state, uint64_t now_ns) {
    if (state->disabled) return S2A_HP_SKIP;
    if (state->retry_at_ns && now_ns < state->retry_at_ns) return S2A_HP_SKIP;
    return S2A_HP_TRY;
}

// 记一次失败；返回 true 表示这一次把设备判死了。
static inline bool s2a_hp_on_fail(s2a_hp_state *state, uint64_t now_ns) {
    state->fails++;
    if (state->fails >= S2A_HP_MAX_FAILS) {
        state->disabled = true;
        state->retry_at_ns = 0;
        return true;
    }
    state->retry_at_ns = now_ns + (uint64_t)S2A_HP_BACKOFF_MS(state->fails) * 1000000ull;
    return false;
}

// 真的播起来了：撤掉退避与判死（引擎被系统复位后又自愈的路径）。
static inline void s2a_hp_on_ok(s2a_hp_state *state) {
    state->fails = 0;
    state->retry_at_ns = 0;
    state->disabled = false;
}

// 换手柄 / 手柄重新接入：给一次新机会。reported 不清——同一局里已经报过的问题不再刷屏。
static inline void s2a_hp_rearm(s2a_hp_state *state) {
    state->fails = 0;
    state->retry_at_ns = 0;
    state->disabled = false;
}

#endif
