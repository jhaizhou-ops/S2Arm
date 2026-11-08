// 手机震动信箱（runtime/src/phone_rumble_mailbox.c）：提交侧只写固定快照 + signal，apply 一律在反馈线程上。
// 为什么钉这个：HID 泵在 _rumbleLock 内同步调 s2a_pad_set_rumble*，compat/.../NpadDevices.cs:49 写明输出钩子
//   不得回调 native 或等 transport IO；真机 A/B 里「首次震动那一刻」同步起 CHHapticEngine 抢 AVAudioSession →
//   音频 stall 2049 ms → s2a_dump_threads thread_suspend 全线程 → 看门狗 SIGKILL。
// 判据：提交返回时 apply 一次都没跑（同步零回调）+ 提交耗远低于一帧；消费不过来只保留最新值；STOP 压过 PLAY。
#include "phone_rumble_mailbox.h"
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static int bad;
static void check(int ok, const char *what) { if (!ok) { printf("✗ %s\n", what); bad++; } }

// apply 侧：可挂住（hold），记录最近若干次 kind 与最新一帧的值。
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_cv = PTHREAD_COND_INITIALIZER;
static int g_hold, g_calls, g_seen[4];
static int g_order[8], g_order_n, g_prev_kind, g_warm_then_play;
static s2a_pad_vibration g_last[2];

static void apply(const s2a_pad_vibration pair[2], int kind) {
    pthread_mutex_lock(&g_mu);
    while (g_hold) pthread_cond_wait(&g_cv, &g_mu);
    g_calls++;
    if (kind >= 0 && kind < 4) g_seen[kind]++;
    if (g_prev_kind == S2A_PHONE_RUMBLE_WARM && kind == S2A_PHONE_RUMBLE_PLAY) g_warm_then_play = 1;
    g_prev_kind = kind;
    if (g_order_n < 8) g_order[g_order_n++] = kind;
    memcpy(g_last, pair, sizeof g_last);
    pthread_cond_broadcast(&g_cv);
    pthread_mutex_unlock(&g_mu);
}
static void hold(int on) { pthread_mutex_lock(&g_mu); g_hold = on; pthread_cond_broadcast(&g_cv); pthread_mutex_unlock(&g_mu); }
static int calls(void) { pthread_mutex_lock(&g_mu); int c = g_calls; pthread_mutex_unlock(&g_mu); return c; }
static int seen(int kind) { pthread_mutex_lock(&g_mu); int c = g_seen[kind]; pthread_mutex_unlock(&g_mu); return c; }

static void ms_abs(struct timespec *ts, int ms) {
    clock_gettime(CLOCK_REALTIME, ts);
    ts->tv_sec += ms / 1000; ts->tv_nsec += (long)(ms % 1000) * 1000000L;
    if (ts->tv_nsec >= 1000000000L) { ts->tv_sec++; ts->tv_nsec -= 1000000000L; }
}
static int wait_seen(int kind, int want, int ms) {   // 等到某类 apply 出现够 want 次
    struct timespec ts; ms_abs(&ts, ms);
    pthread_mutex_lock(&g_mu);
    while (g_seen[kind] < want) if (pthread_cond_timedwait(&g_cv, &g_mu, &ts) != 0) break;
    int ok = g_seen[kind] >= want;
    pthread_mutex_unlock(&g_mu);
    return ok;
}
static double now_ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1e3 + t.tv_nsec / 1e6; }

int main(void) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    if (!s2a_phone_rumble_mailbox_start(apply)) { printf("✗ 反馈线程没起来\n"); return 1; }

    // ① 同步零回调：挂住 apply 再提交，apply 计数必须还是 0，提交本身不得等一帧
    hold(1);
    s2a_pad_vibration v[2] = {{0.5f, 160, 0.5f, 320}, {0.25f, 240, 0, 0}};
    double t0 = now_ms();
    s2a_phone_rumble_mailbox_submit(v);
    double dt = now_ms() - t0;
    check(calls() == 0, "① 提交返回时 apply 一次都没跑（同步零回调）");
    check(dt < 2.0, "① 提交耗时应 < 2 ms（远低于一帧）");
    hold(0);
    check(wait_seen(S2A_PHONE_RUMBLE_PLAY, 1, 2000), "① 放行后 PLAY 到达反馈线程");
    { pthread_mutex_lock(&g_mu);
      check(g_last[0].low_amp == v[0].low_amp && g_last[1].low_amp == v[1].low_amp, "① 值原样送到 apply（左右各一侧）");
      pthread_mutex_unlock(&g_mu); }

    // ② 合并：消费不过来时只保留最新一帧（游戏每秒约 70 次提交，中间帧对震动感知无意义）
    int c0 = seen(S2A_PHONE_RUMBLE_PLAY);
    hold(1);
    for (int i = 0; i < 500; i++) { v[0].low_amp = (float)i / 500.0f; s2a_phone_rumble_mailbox_submit(v); }
    hold(0);
    check(wait_seen(S2A_PHONE_RUMBLE_PLAY, c0 + 1, 2000), "② 500 次连续提交后仍会消费");
    { pthread_mutex_lock(&g_mu); float got = g_last[0].low_amp; int extra = g_seen[S2A_PHONE_RUMBLE_PLAY] - c0;
      pthread_mutex_unlock(&g_mu);
      // 至多 2 次：线程可能在挂住前已取走一帧，放行后再取走「最后一帧」；绝不能是 500 次
      check(extra <= 2, "② 多消费的次数 ≤ 2（不是 500）");
      check(got == 499.0f / 500.0f, "② 最后送到 apply 的是最新一帧的值"); }

    // ③ STOP 压过 PLAY：pair 连写不得把停止饿死在后面
    hold(1);
    for (int i = 0; i < 1000; i++) s2a_phone_rumble_mailbox_submit(v);
    s2a_phone_rumble_mailbox_submit_stop();
    hold(0);
    check(wait_seen(S2A_PHONE_RUMBLE_STOP, 1, 2000), "③ 1000 次 PLAY 之后的 STOP 仍被消费");
    { pthread_mutex_lock(&g_mu); int last = g_order[g_order_n - 1]; pthread_mutex_unlock(&g_mu);
      check(last == S2A_PHONE_RUMBLE_STOP, "③ 停止排在最后消费的那一次（没被 PLAY 盖掉）"); }

    // ④ 预热：空信箱里 WARM 单独被执行（建引擎不播放）
    int w0 = seen(S2A_PHONE_RUMBLE_WARM);
    s2a_phone_rumble_mailbox_warm();
    check(wait_seen(S2A_PHONE_RUMBLE_WARM, w0 + 1, 2000), "④ 空信箱里的 WARM 被执行（预热落到 apply 上）");

    // ④b PLAY 压过 WARM：预热不该把紧接着的真实震动吞掉（要么先 WARM 再 PLAY，要么 WARM 被 PLAY 合并）
    int p0 = seen(S2A_PHONE_RUMBLE_PLAY);
    hold(1);
    s2a_phone_rumble_mailbox_warm();
    s2a_phone_rumble_mailbox_submit(v);
    hold(0);
    check(wait_seen(S2A_PHONE_RUMBLE_PLAY, p0 + 1, 2000), "④b WARM 之后的 PLAY 一定会被消费");
    { pthread_mutex_lock(&g_mu); int seq = g_warm_then_play; int warm = g_seen[S2A_PHONE_RUMBLE_WARM] - w0;
      pthread_mutex_unlock(&g_mu);
      check(seq || warm == 1, "④b WARM 与 PLAY 不互相吞掉（先 WARM 后 PLAY，或 WARM 被 PLAY 合并）"); }

    // ⑤ 计数自洽：submits = applies + 合并掉的次数
    { s2a_phone_rumble_stats s; s2a_phone_rumble_mailbox_stats_get(&s);
      check(s.submits == 1505, "⑤ 提交计数 = 1 + 500 + (1000 + 1) + 1 + (1 + 1)");
      check(s.coalesced > 1400, "⑤ 合并计数记下了被覆盖的提交（诊断能看出来）");
      int synced = 0;
      for (int i = 0; i < 200 && !synced; i++) { s2a_phone_rumble_mailbox_stats_get(&s); synced = s.applies == (uint64_t)calls(); usleep(1000); }
      check(synced, "⑤ apply 计数与回调次数一致"); }

    s2a_phone_rumble_mailbox_shutdown();
    if (bad) { printf("✗ t_phone_rumble_mailbox：%d 处不符\n", bad); return 1; }
    printf("✓ t_phone_rumble_mailbox：提交零回调、合并留最新、STOP 压过 PLAY、WARM 不吃真实震动\n");
    return 0;
}