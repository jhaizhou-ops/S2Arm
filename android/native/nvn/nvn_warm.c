// 预热调度：见 nvn_warm.h 的合同。一个后台线程按「先程序、后管线」的顺序把清单喂完。
#include "nvn_warm.h"
#include "nvn_vk_prog_warm.h"
#include "nvn_vk_pipe_warm.h"
#include "nvn_plat.h"

#include <errno.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>

#define WARM_RETRY 8            // 在途重试槽（程序等编译、管线等程序）
#define WARM_TICK_MS 5          // 没活可做时一轮的睡眠粒度
#define WARM_LOG_MS 5000        // 进度日志间隔
#define WARM_PROG_RETRY_MS 20000   // 程序：编译在途最多等这么久（iOS 的编译服务同样可能十秒级）
#define WARM_PIPE_RETRY_MS 5000    // 管线：等程序发布，正常只差毫秒级
#define WARM_SAVE_MS 30000          // 定期落盘：进程被强杀时最后一次 Stop 不会来，清单不能只靠收尾写
#define WARM_FIRST_SAVE_MS 10000    // 第一次定期落盘（本局前面的记录先落地，别都压在 30 秒之后）
#define WARM_IDLE_MS 250            // 清单做完之后线程留在原地等 Stop 的睡眠粒度（它还要负责定期落盘）

enum { W_IDLE = 0, W_RUNNING = 1, W_STOPPING = 2 };
enum { WHY_DONE = 0, WHY_STOP = 1, WHY_OFF = 2, WHY_NONE = 3 };

static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_exit = PTHREAD_COND_INITIALIZER;   // 预热线程退出时广播（收尾用有界等待，不依赖 pthread_timedjoin_np：bionic 要 _GNU_SOURCE）
static pthread_t g_th;
static int g_state = W_IDLE;      // 受 g_mu
static int g_live;                // 线程还在跑（受 g_mu）
static int g_on = -1;
static int64_t g_t0;
static _Atomic uint64_t g_prog_built, g_prog_failed, g_pipe_built, g_pipe_failed;
static _Atomic int g_why = WHY_DONE;
static _Atomic int g_retired;     // Stop 之后不再起线程

struct prog_retry { struct nvk_prog_rec rec; int64_t first_ms; uint8_t used; };
struct pipe_retry { struct nvk_pipe_rec rec; int64_t first_ms; uint8_t used; };
static struct prog_retry g_pretry[WARM_RETRY];   // 只有预热线程碰
static struct pipe_retry g_qretry[WARM_RETRY];

static int64_t warm_now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static int warm_on(void) {
    if (g_on < 0) g_on = nvn_plat_flag("nvk_warm", 1);
    return g_on;
}

static int warm_stopping(void) {
    pthread_mutex_lock(&g_mu);
    int s = g_state == W_STOPPING;
    pthread_mutex_unlock(&g_mu);
    return s;
}

static void warm_sleep_ms(uint32_t ms) {
    struct timespec ts = {ms / 1000, (long)(ms % 1000) * 1000000L};
    while (nanosleep(&ts, &ts) == -1) { }
}

static void warm_log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void warm_log(const char *fmt, ...) {
    char b[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(b, sizeof b, fmt, ap);
    va_end(ap);
    nvn_plat_log(NVN_PLAT_LOG_INFO, "warm", b);
}

// 验收读数：真实 draw 有没有取到预建对象（draw_hits）、有没有「预热过却仍自备」（draw_miss）。
static void warm_progress(const char *tag) {
    struct nvk_prog_warm_stats ps;
    struct nvk_pipe_warm_stats qs;
    memset(&ps, 0, sizeof ps);
    memset(&qs, 0, sizeof qs);
    nvk_prog_warm_stats(&ps);
    nvk_pipe_warm_stats(&qs);
    warm_log("nvk warm %s: 程序 载入 %llu / 记录 %llu / 建 %llu / 失败 %llu / 本局 draw 命中 %llu 自备 %llu（剩 %llu）；"
             "管线 载入 %llu / 记录 %llu / 建 %llu / 失败 %llu / draw 命中 %llu（剩 %llu）；%lld 毫秒",
             tag,
             (unsigned long long)ps.loaded, (unsigned long long)ps.recorded, (unsigned long long)ps.built,
             (unsigned long long)ps.failed, (unsigned long long)ps.draw_hits, (unsigned long long)ps.draw_miss,
             (unsigned long long)ps.pending,
             (unsigned long long)qs.loaded, (unsigned long long)qs.recorded, (unsigned long long)qs.built,
             (unsigned long long)qs.failed, (unsigned long long)qs.draw_hits, (unsigned long long)qs.pending,
             (long long)(g_t0 ? warm_now_ms() - g_t0 : 0));
}

static int pretry_push(const struct nvk_prog_rec *r) {
    for (int i = 0; i < WARM_RETRY; i++)
        if (!g_pretry[i].used) { g_pretry[i].rec = *r; g_pretry[i].used = 1; g_pretry[i].first_ms = warm_now_ms(); return 0; }
    return -1;
}
static int qretry_push(const struct nvk_pipe_rec *r) {
    for (int i = 0; i < WARM_RETRY; i++)
        if (!g_qretry[i].used) { g_qretry[i].rec = *r; g_qretry[i].used = 1; g_qretry[i].first_ms = warm_now_ms(); return 0; }
    return -1;
}

// 清单加载：本局 profile / 编译闭包可能还没冻结（provider activate 的顺序），最多重试约 10 秒。
// 之后仍拿不到按「本局没有清单」处理：拿不到上下文不是清单坏了，不拿它当失败重试到底。
static int warm_load(void) {
    for (int i = 0; i < 100; i++) {
        if (warm_stopping()) return -1;
        int np = nvk_prog_warm_load();
        int nq = nvk_pipe_warm_load();
        if (np >= 0 || nq >= 0) {
            warm_log("nvk warm 清单：程序 %d 条、管线 %d 条", np, nq);
            return np + nq;
        }
        warm_sleep_ms(100);
    }
    return -2;
}

static void warm_leave(void) {
    pthread_mutex_lock(&g_mu);
    g_live = 0;
    g_state = W_IDLE;
    pthread_cond_broadcast(&g_exit);
    pthread_mutex_unlock(&g_mu);
}

static void *warm_main(void *unused) {
    (void)unused;
    {   // 让出游戏线程：预热只是把关键路径上本来就要做的活提前，不跟游戏抢核（iOS 后台预热同样降 QoS）
        setpriority(PRIO_PROCESS, 0, 5);
        pthread_setname_np(pthread_self(), "nvk-warm");
    }
    g_t0 = warm_now_ms();
    int loaded = warm_load();
    if (loaded < 0) {
        atomic_store(&g_why, loaded == -1 ? WHY_STOP : WHY_NONE);
        warm_log("nvk warm：本局没有可用清单（%d），不预热", loaded);
        warm_leave();
        return NULL;
    }
    struct nvk_prog_rec pr;
    struct nvk_pipe_rec qr;
    // 本局预热集在开局就冻结：只做「上一局落盘、这一局载入」的那批。本局新记录的身份会继续进清单
    // （下一局才用），但不再扩预热集——否则游戏每帧都在产生新身份，预热线程会跟着游戏无限跑，
    // 跟它抢核（真机第二次启动：预热到 105 秒还在跑，帧率 22.6 → 18.0）。
    int prog_budget = nvk_prog_warm_pending();
    int pipe_budget = nvk_pipe_warm_pending();
    int prog_done = 0, idle_rounds = 0, drained = 0;
    int64_t last_log = warm_now_ms(), next_save = g_t0 + WARM_FIRST_SAVE_MS;
    uint64_t saved_rec = 0, saved_pipes = 0;
    for (;;) {
        if (warm_stopping()) { atomic_store(&g_why, WHY_STOP); break; }
        int did = 0;
        // 清单做完了不是「线程退休」：本局还在不断记录新的身份/配方，定期落盘要靠这条线程
        // （bench / 玩家直接杀进程时不会有 Stop，只有这里的周期性 save 能把记录留下来）。
        if (drained) goto idle;
        // 第一遍：程序清单按记录顺序做（热点在前由清单自己保证）。
        if (!prog_done) {
            if (prog_budget <= 0) prog_done = 1;   // 本局预热集做完（本局新记录不再扩集）
            else if (nvk_prog_warm_take(&pr)) {
                prog_budget--;
                int rc = nvk_prog_warm_build(&pr);
                did = 1;
                if (rc == 0) atomic_fetch_add(&g_prog_built, 1);
                else if (rc == 1) { if (pretry_push(&pr)) atomic_fetch_add(&g_prog_failed, 1); }
                else atomic_fetch_add(&g_prog_failed, 1);
            } else {
                prog_done = 1;
            }
        }
        // 第二遍：等编译在途的程序（同身份，编译服务里正在做）。
        if (!did && prog_done) {
            for (int i = 0; i < WARM_RETRY; i++) {
                if (!g_pretry[i].used) continue;
                int rc = nvk_prog_warm_build(&g_pretry[i].rec);
                if (rc == 0) { g_pretry[i].used = 0; atomic_fetch_add(&g_prog_built, 1); }
                else if (rc < 0) { g_pretry[i].used = 0; atomic_fetch_add(&g_prog_failed, 1); }
                else if (warm_now_ms() - g_pretry[i].first_ms > WARM_PROG_RETRY_MS) { g_pretry[i].used = 0; atomic_fetch_add(&g_prog_failed, 1); }
                did = 1;
                break;
            }
        }
        // 第三遍：管线（要程序先发布；程序清单全部走完之后才开始，顺序由这份循环保证）。
        if (!did && prog_done) {
            if (pipe_budget > 0 && nvk_pipe_warm_take(&qr)) {
                pipe_budget--;
                int rc = nvk_pipe_warm_build(&qr);
                did = 1;
                if (rc == 0) atomic_fetch_add(&g_pipe_built, 1);
                else if (rc == 1) { if (qretry_push(&qr)) atomic_fetch_add(&g_pipe_failed, 1); }
                else atomic_fetch_add(&g_pipe_failed, 1);
            }
        }
        if (!did && prog_done) {
            for (int i = 0; i < WARM_RETRY; i++) {
                if (!g_qretry[i].used) continue;
                int rc = nvk_pipe_warm_build(&g_qretry[i].rec);
                if (rc == 0) { g_qretry[i].used = 0; atomic_fetch_add(&g_pipe_built, 1); }
                else if (rc < 0) { g_qretry[i].used = 0; atomic_fetch_add(&g_pipe_failed, 1); }
                else if (warm_now_ms() - g_qretry[i].first_ms > WARM_PIPE_RETRY_MS) { g_qretry[i].used = 0; atomic_fetch_add(&g_pipe_failed, 1); }
                did = 1;
                break;
            }
        }
        if (!did) {
            int more = !prog_done || prog_budget > 0 || pipe_budget > 0;
            int retry_left = 0;
            for (int i = 0; i < WARM_RETRY; i++) retry_left += g_pretry[i].used + g_qretry[i].used;
            if (!more && !retry_left) { drained = 1; atomic_store(&g_why, WHY_DONE); warm_progress("清单完成"); }
            else if (!more && retry_left && ++idle_rounds > 400) { drained = 1; atomic_store(&g_why, WHY_DONE); warm_progress("清单完成（在途重试到期）"); }
            if (more) idle_rounds = 0;
            if (!drained) warm_sleep_ms(WARM_TICK_MS);
        } else {
            idle_rounds = 0;
        }
        {
            int64_t now = warm_now_ms();
            if (!drained && now - last_log >= WARM_LOG_MS) { last_log = now; warm_progress("进度"); }
            // 定期落盘：玩家直接杀进程时没有 Stop，本局记录靠这一步落盘（文件有界，原子写；
            // 内容没变时两个 owner 自己会跳过写盘）。
            if (now >= next_save) {
                next_save = now + WARM_SAVE_MS;
                nvk_prog_warm_save();
                nvk_pipe_warm_save();
                struct nvk_prog_warm_stats ps;
                struct nvk_pipe_warm_stats qs;
                memset(&ps, 0, sizeof ps);
                memset(&qs, 0, sizeof qs);
                nvk_prog_warm_stats(&ps);
                nvk_pipe_warm_stats(&qs);
                if (ps.recorded != saved_rec || qs.recorded != saved_pipes) {
                    saved_rec = ps.recorded;
                    saved_pipes = qs.recorded;
                    warm_log("nvk warm 定期落盘：程序记录 %llu 条、管线记录 %llu 条", (unsigned long long)ps.recorded, (unsigned long long)qs.recorded);
                }
            }
        }
        continue;
idle:
        if (!did) {
            warm_sleep_ms(WARM_IDLE_MS);
            int64_t now = warm_now_ms();
            if (now >= next_save) {
                next_save = now + WARM_SAVE_MS;
                nvk_prog_warm_save();
                nvk_pipe_warm_save();
                struct nvk_prog_warm_stats ps;
                struct nvk_pipe_warm_stats qs;
                memset(&ps, 0, sizeof ps);
                memset(&qs, 0, sizeof qs);
                nvk_prog_warm_stats(&ps);
                nvk_pipe_warm_stats(&qs);
                if (ps.recorded != saved_rec || qs.recorded != saved_pipes) {
                    saved_rec = ps.recorded;
                    saved_pipes = qs.recorded;
                    warm_log("nvk warm 定期落盘：程序记录 %llu 条、管线记录 %llu 条", (unsigned long long)ps.recorded, (unsigned long long)qs.recorded);
                }
            }
        }
    }
    warm_progress(atomic_load(&g_why) == WHY_STOP ? "收工（Stop）" : "完成");
    warm_leave();
    return NULL;
}

void nvk_warm_start(void) {
    if (!warm_on()) { atomic_store(&g_why, WHY_OFF); return; }
    pthread_mutex_lock(&g_mu);
    if (g_state != W_IDLE || g_live || atomic_load(&g_retired)) { pthread_mutex_unlock(&g_mu); return; }
    memset(g_pretry, 0, sizeof g_pretry);
    memset(g_qretry, 0, sizeof g_qretry);
    atomic_store(&g_why, WHY_DONE);
    g_state = W_RUNNING;
    g_live = 1;
    int rc = pthread_create(&g_th, NULL, warm_main, NULL);
    if (rc) {
        g_live = 0;
        g_state = W_IDLE;
        pthread_mutex_unlock(&g_mu);
        nvn_plat_log(NVN_PLAT_LOG_RED, "warm", "nvk warm：预热线程起不来（本局不预热，首次使用照旧同步准备）");
        return;
    }
    pthread_mutex_unlock(&g_mu);
    warm_log("nvk warm：预热线程已起（debug.s2a.nvk_warm=1；设 0 关）");
}

void nvk_warm_stop(void) {
    pthread_mutex_lock(&g_mu);
    if (g_state == W_RUNNING) g_state = W_STOPPING;
    int live = g_live;
    pthread_t th = g_th;
    pthread_mutex_unlock(&g_mu);
    if (live) {
        // 有界等它自己走到退出点（condvar 到点就返回，不依赖 GNU 的 timedjoin）。到点仍没退：
        // 如实报红、不 join（进程正在收尾，迟到的结果由各 owner 的停局判定丢弃），也不假装回收了。
        struct timespec dl;
        clock_gettime(CLOCK_REALTIME, &dl);
        dl.tv_nsec += 150L * 1000000L;
        while (dl.tv_nsec >= 1000000000L) { dl.tv_sec++; dl.tv_nsec -= 1000000000L; }
        pthread_mutex_lock(&g_mu);
        while (g_live) {
            if (pthread_cond_timedwait(&g_exit, &g_mu, &dl) == ETIMEDOUT) break;
        }
        int still = g_live;
        pthread_mutex_unlock(&g_mu);
        if (still) {
            nvn_plat_log(NVN_PLAT_LOG_RED, "warm", "nvk warm：预热线程 150 毫秒内没退出（迟到的结果由各 owner 的停局判定丢弃）");
        } else if (pthread_join(th, NULL) == 0) {
            pthread_mutex_lock(&g_mu);
            g_live = 0;
            pthread_mutex_unlock(&g_mu);
        }
    }
    // 收尾顺序：线程请停 → 后台在途收拢 → 清单落盘。代际 / 停局校验在各 owner 里，这里不重复。
    if (nvk_shader_warm_quiesce(100))
        nvn_plat_log(NVN_PLAT_LOG_RED, "warm", "nvk warm：后台构建没在预算内静默（清单照写，迟到结果由 owner 丢弃）");
    nvk_prog_warm_save();
    nvk_pipe_warm_save();
    atomic_store(&g_retired, 1);
    warm_progress("收尾");
}

int nvk_warm_active(void) {
    pthread_mutex_lock(&g_mu);
    int a = g_live;
    pthread_mutex_unlock(&g_mu);
    return a;
}

void nvk_warm_totals(struct nvk_warm_totals *out) {
    if (!out) return;
    memset(out, 0, sizeof *out);
    out->prog_built = atomic_load(&g_prog_built);
    out->prog_failed = atomic_load(&g_prog_failed);
    out->pipe_built = atomic_load(&g_pipe_built);
    out->pipe_failed = atomic_load(&g_pipe_failed);
    out->ms = g_t0 ? (uint64_t)(warm_now_ms() - g_t0) : 0;
    out->why = atomic_load(&g_why);
}
