#include "phone_rumble_mailbox.h"
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>
#if defined(__APPLE__)
#include <pthread/qos.h>
#include "s2a_qos.h"   // 全进程线程调度档一张表
#endif

// 单槽信箱 + 粘性停止位。震动是瞬时感知：消费不过来时只保留最新一帧是对的（游戏每秒约 70 次提交），
//   但 STOP 必须压过 PLAY，否则连续提交会把停止饿死在队列后面。
typedef enum { MB_NONE = 0, MB_WARM = 1, MB_PLAY = 2, MB_STOP = 3 } mb_kind;

static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_cv = PTHREAD_COND_INITIALIZER;
static pthread_t g_thread;
static int g_running, g_quit;
static mb_kind g_want;
static s2a_pad_vibration g_pair[2];
static _Atomic(s2a_phone_rumble_apply) g_apply;
static _Atomic uint64_t g_submits, g_applies, g_coalesced;

static void *mb_run(void *arg) {
    (void)arg;
#if defined(__APPLE__)
    s2a_qos_set_self(S2A_QOS_HOST_AUX);   // 震动要按时到，但不抢音频 / 渲染的优先级（s2a_qos.h）
#endif
    for (;;) {
        pthread_mutex_lock(&g_mu);
        while (!g_quit && g_want == MB_NONE) pthread_cond_wait(&g_cv, &g_mu);
        if (g_want == MB_NONE) { pthread_mutex_unlock(&g_mu); break; }   // 只剩 g_quit
        mb_kind kind = g_want;
        g_want = MB_NONE;
        s2a_pad_vibration pair[2];
        memcpy(pair, g_pair, sizeof pair);
        pthread_mutex_unlock(&g_mu);
        s2a_phone_rumble_apply apply = atomic_load(&g_apply);
        if (apply) { apply(pair, (int)kind); atomic_fetch_add(&g_applies, 1); }
    }
    pthread_mutex_lock(&g_mu);
    g_running = 0;
    pthread_mutex_unlock(&g_mu);
    return NULL;
}

int s2a_phone_rumble_mailbox_start(s2a_phone_rumble_apply apply) {
    if (apply) atomic_store(&g_apply, apply);
    pthread_mutex_lock(&g_mu);
    if (!g_running) {
        g_quit = 0;
        if (pthread_create(&g_thread, NULL, mb_run, NULL) == 0) g_running = 1;
    }
    int running = g_running;
    pthread_mutex_unlock(&g_mu);
    return running;
}

static void mb_post(mb_kind kind, const s2a_pad_vibration pair[2]) {
    atomic_fetch_add(&g_submits, 1);
    pthread_mutex_lock(&g_mu);
    if (pair) memcpy(g_pair, pair, sizeof g_pair);
    if (kind > g_want) {
        if (g_want != MB_NONE) atomic_fetch_add(&g_coalesced, 1);
        g_want = kind;
    } else {
        atomic_fetch_add(&g_coalesced, 1);   // PLAY 追在 PLAY/STOP 后面、WARM 追在任何东西后面：只更新值，不再多排一次
    }
    pthread_cond_signal(&g_cv);
    pthread_mutex_unlock(&g_mu);
}

void s2a_phone_rumble_mailbox_submit(const s2a_pad_vibration pair[2]) { mb_post(MB_PLAY, pair); }
void s2a_phone_rumble_mailbox_submit_stop(void) { mb_post(MB_STOP, NULL); }
void s2a_phone_rumble_mailbox_warm(void) { mb_post(MB_WARM, NULL); }

void s2a_phone_rumble_mailbox_stats_get(s2a_phone_rumble_stats *out) {
    if (!out) return;
    out->submits = atomic_load(&g_submits);
    out->applies = atomic_load(&g_applies);
    out->coalesced = atomic_load(&g_coalesced);
}

void s2a_phone_rumble_mailbox_shutdown(void) {
    pthread_mutex_lock(&g_mu);
    g_quit = 1;
    pthread_cond_broadcast(&g_cv);
    int running = g_running;
    pthread_mutex_unlock(&g_mu);
    if (running) pthread_join(g_thread, NULL);
}
