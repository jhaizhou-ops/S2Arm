// GPU 挂死看门狗（T10 / #635）：见 gal_gpuwd.h 顶部的分工说明。缺省关。
//
// 判据：栅栏 f 在提交时刻登记；已完成的栅栏号由完成回执推进。最老的在途栅栏 = done + 1（gal_core 每次提交 +1、连续）。
//   age = now − 该栅栏的提交时刻。age 超过阈值就判卡死。不看「谁在等」，所以不看等的人还活着没有。
// 三个环境变量（都在第一次提交时读一次）：
//   NXGAL_GPU_WD_MS=<n>          0 / 不设 = 关（缺省）；>0 = 超过 n 毫秒未完成即判卡死（Mac 建议起步 8000，见 gal_gpuwd.h）
//   NXGAL_GPU_WD_MODE=exit|log   缺省 exit（_exit(86)，与 gal_gpu_exit 同码）；log = 只记不退（量误判用）
//   NXGAL_GPU_WD_SLOW_MS=<n>     先打一行「慢」的阈值，缺省 = 判死阈值的一半
//   NXGAL_GPU_WD_DUMP=1          判死时先跑 s2a_dump_threads 取全线程现场（缺省不跑，见下）
//   NXGAL_GPU_WD_STALL_MS=<n>    看门狗自己晚到超过 n 毫秒 = 整机被饿着，这一拍不判，缺省 2000
//
// 为什么判死时缺省不跑 s2a_dump_threads：那条路径 thread_suspend 除本线程外全部线程，再逐条取寄存器 / 回溯 48 帧。
//   在 GPU 已挂的进程里，这会把「退出」推迟几十到几百毫秒，而退出本身是唯一能释放 GPU 队列的动作；
//   被挂起的线程里若有正持 Metal 驱动内部锁的，还可能让驱动侧的完成回执发不出去。现场默认只要最小集
//   （栅栏号 / 年龄 / 帧号 / 在途条数），要全线程回溯的局显式 NXGAL_GPU_WD_DUMP=1。
#include "gal_gpuwd.h"
#include <dlfcn.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// 在途命令缓冲的登记环：一个槽按 栅栏号 % WD_RING 存提交时刻。正常情况下在途只有个位数（主队列 + 预载 + 分段），
// 256 足够；超出就认不出（读到的槽栅栏号对不上），那一拍不判 —— 宁可漏判也不误杀
#define WD_RING 256
// 看门狗自己的节拍（毫秒）：够细，也不给整机加可见负载（缺省关，只有复现局 / 诊断才开）
#define WD_SLICE_MS 20

static _Atomic uint64_t g_cf[WD_RING];   // 该槽登记的栅栏号（0 = 空）
static _Atomic uint64_t g_ct[WD_RING];   // 该栅栏的提交时刻（CLOCK_UPTIME_RAW，ns）
// 该栅栏提交时的现场（gal_gpuwd_scene 逐字段拆成原子量）。发布顺序：先写现场、再推 g_committed；
//   看门狗只在 g_committed 已越过该栅栏后才读这一槽，所以读到的一定是这次提交写下的数
typedef struct { _Atomic uint32_t draws, encs, pw, ph, pf, pd, pk; _Atomic uint64_t frame; } wd_scene;
static wd_scene g_cs[WD_RING];
static _Atomic uint64_t g_committed;     // 已登记的最大栅栏号
static _Atomic uint64_t g_done;          // 已完成的最大栅栏号
static _Atomic int g_started;            // 看门狗线程起过没有
static _Atomic uint64_t g_blind_ns;      // 上次打「看不见」那行的时刻（每 5 秒最多一行）
static _Atomic uint64_t g_warn_fence;    // 已经打过「慢」的栅栏号（每条只打一次）
static _Atomic uint64_t g_fire_fence;    // 已经报过的栅栏号（mode=log 时防每拍刷一行）

// 配置（第一次提交时读一次；之后不再看环境变量）
static int g_ms;            // 判死阈值；0 = 关
static int g_slow_ms;       // 「慢」阈值
static int g_mode_log;      // 1 = 只记不退
static int g_dump;          // 1 = 判死时跑全线程现场
static uint64_t g_stall_ms; // 看门狗自己晚到多少算整机被饿着

static void (*g_log)(const char *line);
static void (*g_exit_hook)(int code);

static uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

// 原生层全线程现场（runtime/src/tdump.c，s2a_native.h v2.9）。运行时按名找、不在链接期留引用：
//   显卡层单测不链原生层时 dlsym 返回 NULL、跳过；宿主 / iOS 包链原生层时取到真函数。只在判死那一拍查一次
static int (*dump_threads_fn(void))(const char *) {
    static int (*fp)(const char *);
    static int done;
    if (!done) { done = 1; fp = (int (*)(const char *))dlsym(RTLD_DEFAULT, "s2a_dump_threads"); }
    return fp;
}

static void wd_log(const char *line) {
    if (g_log) { g_log(line); return; }
    fprintf(stderr, "[gal] %s\n", line);
    fflush(stderr);
}

// 判据（纯函数，单测直接调；不读任何全局）
int gal_gpuwd_test_decide(uint64_t age_ms, uint64_t late_ms) {
    if (!g_ms) return 0;                                   // 关着
    if (late_ms > g_stall_ms) return 0;                    // 看门狗自己晚到 = 整机被饿着，不是 GPU 挂死（Chromium kUnreasonableTimeoutDelay 同口径）
    if ((int)age_ms < g_slow_ms) return 0;
    if ((int)age_ms < g_ms) return 1;                      // 只打「慢」
    return 2;                                              // 判卡死
}

int gal_gpuwd_on(void) { return g_ms > 0; }

// 配置读一次。pthread_once 只在第一条提交线程上跑，不进程序里最热的路径
static pthread_once_t g_once = PTHREAD_ONCE_INIT;
static void wd_read_env(void) {
    const char *v = getenv("NXGAL_GPU_WD_MS");
    g_ms = v && *v ? atoi(v) : 0;
    if (g_ms <= 0) { g_ms = 0; return; }                   // 关：后面全不建
    v = getenv("NXGAL_GPU_WD_SLOW_MS");
    g_slow_ms = v && *v ? atoi(v) : g_ms / 2;
    if (g_slow_ms <= 0 || g_slow_ms > g_ms) g_slow_ms = g_ms;
    v = getenv("NXGAL_GPU_WD_MODE");
    g_mode_log = v && !strcmp(v, "log");
    v = getenv("NXGAL_GPU_WD_DUMP");
    g_dump = v && *v && strcmp(v, "0");
    v = getenv("NXGAL_GPU_WD_STALL_MS");
    g_stall_ms = v && *v ? (uint64_t)atoll(v) : 2000;
}

void gal_gpuwd_set_log(void (*fn)(const char *line)) { g_log = fn; }

static void wd_fire(uint64_t fence, uint64_t age_ms, uint64_t t) {
    // 同一条栅栏只报一次（mode=log 时看门狗会一直转到它完成）
    uint64_t prev = atomic_load(&g_fire_fence);
    if (prev == fence) return;
    atomic_store(&g_fire_fence, fence);

    uint64_t done = atomic_load(&g_done), comm = atomic_load(&g_committed);
    int inflight = (int)(comm > done ? comm - done : 0);
    // 现场只取提交时登记进环的整数（不回调宿主、不碰 Metal：GPU 已挂时那些调用本身可能再堵住，现场就写不出来）
    const wd_scene *c = &g_cs[fence % WD_RING];
    uint32_t dr = atomic_load_explicit(&c->draws, memory_order_relaxed), en = atomic_load_explicit(&c->encs, memory_order_relaxed);
    uint64_t fr = atomic_load_explicit(&c->frame, memory_order_relaxed);
    uint32_t pw = atomic_load_explicit(&c->pw, memory_order_relaxed), ph = atomic_load_explicit(&c->ph, memory_order_relaxed);
    uint32_t pf = atomic_load_explicit(&c->pf, memory_order_relaxed), pd = atomic_load_explicit(&c->pd, memory_order_relaxed);
    uint32_t pk = atomic_load_explicit(&c->pk, memory_order_relaxed);
    // 读的途中该槽被后来的提交覆盖（在途超过 WD_RING 条）就不报这组数，免得把别批的现场安到这条栅栏上
    int ok = atomic_load(&g_cf[fence % WD_RING]) == fence;
    char line[1024];
    if (ok)
        snprintf(line, sizeof line,
                 "【红】GPU 挂死看门狗：栅栏 %llu 提交后 %llu ms 未完成（阈值 %d ms，在途 %d 条，已完成到 %llu）；"
                 "帧 %llu，本批绘制 + 派发 %u、编码器 %u，最后在录通道 %ux%u 格式 %u 绘制 %u 类 %u",
                 (unsigned long long)fence, (unsigned long long)age_ms, g_ms, inflight, (unsigned long long)done,
                 (unsigned long long)fr, dr, en, pw, ph, pf, pd, pk);
    else
        snprintf(line, sizeof line,
                 "【红】GPU 挂死看门狗：栅栏 %llu 提交后 %llu ms 未完成（阈值 %d ms，在途 %d 条，已完成到 %llu）；现场槽已被后来的提交覆盖",
                 (unsigned long long)fence, (unsigned long long)age_ms, g_ms, inflight, (unsigned long long)done);
    wd_log(line);
    if (g_mode_log) return;   // 只记不退：量误判用，正式局不许开
    if (g_dump) {
        int (*dt)(const char *) = dump_threads_fn();
        if (dt) dt("GPU 挂死看门狗");   // 缺省不跑（见文件头），NXGAL_GPU_WD_DUMP=1 才走
    }
    (void)t;
    fflush(NULL);
    if (g_exit_hook) { g_exit_hook(86); return; }
    _exit(86);   // 与 gal_gpu_exit 同码：上层执行器按 86 = 红。不做优雅退出、不尝试恢复
}

// 一拍：读三个原子量算最老在途栅栏的年龄，按判据决定。不取任何锁、不调 Metal
static void wd_tick(uint64_t t, uint64_t late_ns) {
    uint64_t done = atomic_load(&g_done), comm = atomic_load(&g_committed);
    if (comm <= done) return;                    // 没有在途的
    uint64_t want = done + 1;                    // 最老的在途栅栏（gal_core 每次提交 +1、连续）
    int i = (int)(want % WD_RING);
    if (atomic_load(&g_cf[i]) != want) {
        // 认不出：在途超过 WD_RING 条，或这条提交路径没接上登记。每 5 秒打一行，免得看门狗悄悄失效
        uint64_t last = atomic_load(&g_blind_ns);
        if (!last || t - last >= 5000000000ull) {
            atomic_store(&g_blind_ns, t);
            char line[256];
            snprintf(line, sizeof line,
                     "GPU 挂死看门狗：栅栏 %llu 没有登记（在途 %llu 条，环 %d）——本拍不判，提交路径可能没接上",
                     (unsigned long long)want, (unsigned long long)(comm - done), WD_RING);
            wd_log(line);
        }
        return;
    }
    uint64_t t0 = atomic_load(&g_ct[i]);
    uint64_t age_ms = (t - t0) / 1000000ull;
    switch (gal_gpuwd_test_decide(age_ms, late_ns / 1000000ull)) {
        case 1: {
            if (atomic_load(&g_warn_fence) == want) return;
            atomic_store(&g_warn_fence, want);
            char line[512];
            snprintf(line, sizeof line, "GPU 慢：栅栏 %llu 提交后 %llu ms 未完成（判死阈值 %d ms），继续等",
                     (unsigned long long)want, (unsigned long long)age_ms, g_ms);
            wd_log(line);
            return;
        }
        case 2: wd_fire(want, age_ms, t); return;
        default: return;
    }
}

static void *wd_main(void *a) {
    (void)a;
    // 提到 USER_INTERACTIVE：GPU 挂死时整机多半在别处挤，普通 QoS 的线程可能拿不到片。只做算术，不占 CPU
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    uint64_t slice = (uint64_t)WD_SLICE_MS * 1000000ull;
    uint64_t prev = now_ns();
    for (;;) {
        struct timespec ts = {0, (long)slice};
        nanosleep(&ts, NULL);
        uint64_t t = now_ns();
        uint64_t gap = t - prev;
        prev = t;
        // 自己晚到多少：这一拍与上一拍的间隔超过 节拍 + 容忍量
        uint64_t late = gap > slice + g_stall_ms * 1000000ull ? gap - slice : 0;
        wd_tick(t, late);
    }
    return NULL;
}

static void wd_start_once(void) {
    if (atomic_exchange(&g_started, 1)) return;
    pthread_attr_t at;
    if (pthread_attr_init(&at)) return;
    pthread_attr_setdetachstate(&at, PTHREAD_CREATE_DETACHED);
    pthread_t th;
    if (pthread_create(&th, &at, wd_main, NULL) != 0) {
        atomic_store(&g_started, 0);
        wd_log("【红】GPU 挂死看门狗：起线程失败，本次不判");
    }
    pthread_attr_destroy(&at);
}

void gal_gpuwd_on_commit(uint64_t fence, const gal_gpuwd_scene *sc) {
    if (!fence) return;
    pthread_once(&g_once, wd_read_env);
    if (!g_ms) return;
    static const gal_gpuwd_scene zero;
    if (!sc) sc = &zero;
    int i = (int)(fence % WD_RING);
    atomic_store(&g_cf[i], fence);   // 先换栅栏号：看门狗读现场前后各比一次，覆盖中途就认得出
    wd_scene *s = &g_cs[i];
    atomic_store_explicit(&s->draws, sc->draws, memory_order_relaxed); atomic_store_explicit(&s->encs, sc->encs, memory_order_relaxed);
    atomic_store_explicit(&s->frame, sc->frame, memory_order_relaxed);
    atomic_store_explicit(&s->pw, sc->pass_w, memory_order_relaxed); atomic_store_explicit(&s->ph, sc->pass_h, memory_order_relaxed);
    atomic_store_explicit(&s->pf, sc->pass_fmt, memory_order_relaxed); atomic_store_explicit(&s->pd, sc->pass_draws, memory_order_relaxed);
    atomic_store_explicit(&s->pk, sc->pass_kind, memory_order_relaxed);
    atomic_store(&g_ct[i], now_ns());
    uint64_t c = atomic_load(&g_committed);
    while (c < fence && !atomic_compare_exchange_weak(&g_committed, &c, fence)) {}
    wd_start_once();
}

void gal_gpuwd_on_done(uint64_t done) {
    if (!g_ms || !done) return;
    uint64_t d = atomic_load(&g_done);
    while (d < done && !atomic_compare_exchange_weak(&g_done, &d, done)) {}
}

// ---------- 单测钩子 ----------
void gal_gpuwd_test_set_exit(void (*fn)(int code)) { g_exit_hook = fn; }
void gal_gpuwd_test_reset(void) {
    for (int i = 0; i < WD_RING; i++) { atomic_store(&g_cf[i], 0); atomic_store(&g_ct[i], 0); }
    atomic_store(&g_committed, 0); atomic_store(&g_done, 0);
    atomic_store(&g_warn_fence, 0); atomic_store(&g_fire_fence, 0); atomic_store(&g_blind_ns, 0);
    memset(g_cs, 0, sizeof g_cs);
    g_log = NULL; g_exit_hook = NULL;
    // g_ms / g_started 不复位：环境变量只读一次、线程只起一次，复位会与在跑的线程打架
}
uint64_t gal_gpuwd_test_inflight(void) {
    uint64_t d = atomic_load(&g_done), c = atomic_load(&g_committed);
    return c > d ? c - d : 0;
}
