// nvn_vk_pipe_demand 宿主集成测：fake 建管线驱动 demand 后台线程。
// 覆盖：kick→PENDING→后台建→READY；后台失败；不同着色器配方隔离；超时 stop 保留 worker 并阻止重启，回收后可安全重开。
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#include "nvn_backend.h"
#include "nvn_plat.h"
#include "rp_shader.h"
#include "nvn_vk_pipe_demand.h"

// 后台建管线是 worker 池：生命周期断言按「本配置应有的条数」比，取值与被测代码共用同一处（不各抄一份夹值逻辑）。
static int want_workers(void) { return nvn_vk_pipe_demand_workers_configured(); }

static int g_test_workers = -1;   // >0：覆盖 nvk_pipe_workers（用例把池压到指定条数才好观察顺序）
static int g_order[64], g_order_n;   // 后端实际建管线的顺序（用 desc.prim 标记）
struct priority_wait_arg { const nvn_gpu_pipe_desc *d; const uint8_t *id; int rc; nvn_gpu_pipe out; char why[128]; };
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static nvn_gpu_pipe g_installed;
static nvn_gpu_pipe_desc g_inst_desc;
static int g_has_inst;
static int g_fail_next;
static int g_build_calls;
static int g_gate_hold, g_gate_entered;
static pthread_cond_t g_cv = PTHREAD_COND_INITIALIZER;

int nvn_gpu_pipe_lookup(const nvn_gpu_pipe_desc *d, nvn_gpu_pipe *out) {
    if (out) *out = NULL;
    pthread_mutex_lock(&g_mu);
    int hit = g_has_inst && d && memcmp(d, &g_inst_desc, sizeof *d) == 0;
    if (hit && out) *out = g_installed;
    pthread_mutex_unlock(&g_mu);
    return hit;
}
nvn_gpu_rc nvn_gpu_pipe_get(const nvn_gpu_pipe_desc *d, int mode, nvn_gpu_pipe *out, nvn_gpu_err *err) {
    (void)mode;
    pthread_mutex_lock(&g_mu);
    g_build_calls++;
    if (g_order_n < 64) g_order[g_order_n++] = (int)d->prim;   // 记录建管线顺序（用例断言插队效果）
    while (g_gate_hold) {
        g_gate_entered = 1;
        pthread_cond_broadcast(&g_cv);
        pthread_cond_wait(&g_cv, &g_mu);
    }
    int fail = g_fail_next;
    nvn_gpu_pipe built = (nvn_gpu_pipe)(uintptr_t)(0x9000 + g_build_calls);
    if (!fail) { g_inst_desc = *d; g_installed = built; g_has_inst = 1; }
    if (out) *out = fail ? NULL : built;
    pthread_mutex_unlock(&g_mu);
    nvn_gpu_rc r; r.code = fail ? NVN_GPU_E_COMPILE : NVN_GPU_OK;
    if (fail && err) snprintf(err->why, sizeof err->why, "fake compile fail");
    return r;
}
int nvn_plat_flag(const char *name, int dflt) {
    if (!strcmp(name, "nvk_pipe_async")) return 1;
    if (!strcmp(name, "nvk_pipe_workers") && g_test_workers > 0) return g_test_workers;   // 用例可把池压到指定条数
    return dflt;
}
static _Atomic int g_start_denial_logs;
static char g_last_start_denial[160];
void nvn_plat_log(int level, const char *cls, const char *text) {
    if (level != NVN_PLAT_LOG_WARN || !cls || strcmp(cls, "pipe-demand") != 0 || !text) return;
    snprintf(g_last_start_denial, sizeof g_last_start_denial, "%s", text);
    atomic_fetch_add_explicit(&g_start_denial_logs, 1, memory_order_release);
}
static struct rp_prog g_prog;
int rp_shader_prog_borrow(const uint8_t identity[32], const struct rp_prog **out) { (void)identity; if (out) *out = &g_prog; return 1; }
void rp_shader_prog_return(const uint8_t identity[32]) { (void)identity; }

static int fails;
#define CHECK(c, m) do { if (!(c)) { printf("FAIL: %s (line %d)\n", m, __LINE__); fails++; } } while (0)

static void set_ident(uint8_t *id, uint8_t v) { memset(id, v, 32); }
static uint64_t mono_ns(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (uint64_t)t.tv_sec * 1000000000ull + (uint64_t)t.tv_nsec; }
static int wait_gate_entered(uint32_t ms) {
    struct timespec until; clock_gettime(CLOCK_REALTIME, &until);
    until.tv_sec += (time_t)(ms / 1000); until.tv_nsec += (long)(ms % 1000) * 1000000L;
    if (until.tv_nsec >= 1000000000L) { until.tv_sec++; until.tv_nsec -= 1000000000L; }
    pthread_mutex_lock(&g_mu);
    while (!g_gate_entered) if (pthread_cond_timedwait(&g_cv, &g_mu, &until) != 0) break;
    int entered = g_gate_entered;
    pthread_mutex_unlock(&g_mu);
    return entered;
}
static void gate_release(void) {
    pthread_mutex_lock(&g_mu); g_gate_hold = 0; pthread_cond_broadcast(&g_cv); pthread_mutex_unlock(&g_mu);
}
static int wait_demand_idle(uint32_t ms) {
    uint64_t end = mono_ns() + (uint64_t)ms * 1000000ull;
    do {
        if (nvn_vk_pipe_demand_quiescent()) return 1;
        struct timespec ts = {0, 1000000L}; nanosleep(&ts, NULL);
    } while (mono_ns() < end);
    return nvn_vk_pipe_demand_quiescent();
}
static int wait_lifecycle_busy(uint32_t ms) {
    uint64_t end = mono_ns() + (uint64_t)ms * 1000000ull;
    do {
        if (nvn_vk_pipe_demand_test_lifecycle_busy()) return 1;
        struct timespec ts = {0, 1000000L}; nanosleep(&ts, NULL);
    } while (mono_ns() < end);
    return nvn_vk_pipe_demand_test_lifecycle_busy();
}
struct start_thread_arg { _Atomic int done; };
static void *start_thread_main(void *opaque) {
    struct start_thread_arg *arg = opaque;
    nvn_vk_pipe_demand_start();
    atomic_store_explicit(&arg->done, 1, memory_order_release);
    return NULL;
}
struct stop_thread_arg { _Atomic int done; uint64_t elapsed_ms; };
static void *stop_thread_main(void *opaque) {
    struct stop_thread_arg *arg = opaque;
    uint64_t start = mono_ns();
    nvn_vk_pipe_demand_stop();
    arg->elapsed_ms = (mono_ns() - start) / 1000000ull;
    atomic_store_explicit(&arg->done, 1, memory_order_release);
    return NULL;
}
enum demand_event { DEMAND_WORKER_START, DEMAND_WORKER_EXIT, DEMAND_BACKEND_RELEASE };
static int demand_events_safe(const enum demand_event *events, size_t count) {
    int active = 0;
    for (size_t i = 0; i < count; i++) {
        if (events[i] == DEMAND_WORKER_START) {
            if (active) return 0;
            active = 1;
        } else if (events[i] == DEMAND_WORKER_EXIT) {
            if (!active) return 0;
            active = 0;
        } else if (events[i] == DEMAND_BACKEND_RELEASE && active) {
            return 0;
        }
    }
    return active == 0;
}


// ---------------- 池 / 插队 / 并发去重（#2112 复审要求的三条，每条都有对应变异档） ----------------

static void *priority_wait_main(void *opaque) {
    struct priority_wait_arg *a = opaque;
    a->rc = nvn_vk_pipe_demand_wait(a->d, a->id, 4000, &a->out, a->why, sizeof a->why);
    return NULL;
}

// 插队：卡住唯一一条 worker 后依次 kick A、B、C，再让另一个线程等 C。
// 期望：放开后 C 第一个被建（队列顺序 A、C、B）、只建 3 条、插队计数 +1。
// 变异档 noprioritize（去掉 wait 里的 dem_prioritize）：顺序变 A、B、C，本用例红。
static void t_priority(void) {
    g_test_workers = 1;
    nvn_vk_pipe_demand_stop(); nvn_vk_pipe_demand_start();   // start 会重置统计：基线必须在它之后取
    struct nvn_pipe_demand_stats s0; nvn_vk_pipe_demand_stats(&s0);
    CHECK(nvn_vk_pipe_demand_worker_count() == 1, "priority: pool down to one worker");
    pthread_mutex_lock(&g_mu); g_gate_hold = 1; g_gate_entered = 0; g_order_n = 0; pthread_mutex_unlock(&g_mu);

    nvn_gpu_pipe_desc A, B, C;
    memset(&A, 0, sizeof A); memset(&B, 0, sizeof B); memset(&C, 0, sizeof C);
    A.st[0].sh = (nvn_gpu_shader)(uintptr_t)0xA1; A.prim = 1;
    B.st[0].sh = (nvn_gpu_shader)(uintptr_t)0xB1; B.prim = 2;
    C.st[0].sh = (nvn_gpu_shader)(uintptr_t)0xC1; C.prim = 3;
    uint8_t ia[32], ib[32], ic[32]; set_ident(ia, 0xA1); set_ident(ib, 0xB1); set_ident(ic, 0xC1);
    nvn_gpu_pipe cached;
    CHECK(nvn_vk_pipe_demand_kick(&A, ia, &cached) == NVK_DEMAND_PENDING, "priority: A queued");
    CHECK(wait_gate_entered(1000), "priority: worker is busy building A");
    CHECK(nvn_vk_pipe_demand_kick(&B, ib, &cached) == NVK_DEMAND_PENDING, "priority: B queued behind A");
    CHECK(nvn_vk_pipe_demand_kick(&C, ic, &cached) == NVK_DEMAND_PENDING, "priority: C queued behind B");

    struct priority_wait_arg w; memset(&w, 0, sizeof w);
    w.d = &C; w.id = ic; w.rc = -1;
    pthread_t th;
    if (pthread_create(&th, NULL, priority_wait_main, &w) == 0) {
        struct timespec ts = {0, 150000000L}; nanosleep(&ts, NULL);   // 让等待线程先把 C 挪到队首
        gate_release();
        pthread_join(th, NULL);
        CHECK(w.rc == 0 && w.out != NULL, "priority: waiting thread gets C built");
    } else {
        CHECK(0, "priority: create waiter thread");
        gate_release();
    }
    nvn_gpu_pipe ob = NULL, oa = NULL; char wb[128], wa[128];   // 注意：wait 的 out 不能给 NULL（READY 时会写入）
    nvn_vk_pipe_demand_wait(&B, ib, 4000, &ob, wb, sizeof wb);
    nvn_vk_pipe_demand_wait(&A, ia, 4000, &oa, wa, sizeof wa);
    pthread_mutex_lock(&g_mu);
    int n = g_order_n, o0 = n > 0 ? g_order[0] : 0, o1 = n > 1 ? g_order[1] : 0, o2 = n > 2 ? g_order[2] : 0;
    pthread_mutex_unlock(&g_mu);
    CHECK(n == 3 && o0 == 1 && o1 == 3 && o2 == 2, "priority: build order is A, C, B");
    struct nvn_pipe_demand_stats s1; nvn_vk_pipe_demand_stats(&s1);    CHECK(s1.built - s0.built == 3, "priority: three pipelines built, not four");
    CHECK(s1.prioritized - s0.prioritized == 1, "priority: prioritized counter incremented once");
    nvn_vk_pipe_demand_stop();
    CHECK(wait_demand_idle(3000), "priority: pool stops cleanly");
}

// 池收尾：三条 worker 同时卡在建管线里时 stop 要在有界等待内返回，期间 quiescent 为假；
// 放开后 quiescent 变真、worker_count 归零。
// 变异档 noreap（reap 不 join）：放开后 running 一直不清，本用例红。
static void t_pool_stop(void) {
    g_test_workers = 3;
    nvn_vk_pipe_demand_stop(); nvn_vk_pipe_demand_start();
    CHECK(nvn_vk_pipe_demand_worker_count() == 3, "pool stop: three workers running");
    pthread_mutex_lock(&g_mu); g_gate_hold = 1; g_gate_entered = 0; int base = g_build_calls; pthread_mutex_unlock(&g_mu);
    for (int i = 0; i < 3; i++) {
        nvn_gpu_pipe_desc d; memset(&d, 0, sizeof d);
        d.st[0].sh = (nvn_gpu_shader)(uintptr_t)(0xD0u + (unsigned)i);
        d.prim = 20u + (unsigned)i;
        uint8_t id[32]; set_ident(id, (uint8_t)(0xD0 + i));
        nvn_gpu_pipe cached;
        CHECK(nvn_vk_pipe_demand_kick(&d, id, &cached) == NVK_DEMAND_PENDING, "pool stop: key queued");
    }
    int entered = 0;
    for (int i = 0; i < 2000 && entered < 3; i++) {
        pthread_mutex_lock(&g_mu); entered = g_build_calls - base; pthread_mutex_unlock(&g_mu);
        if (entered < 3) { struct timespec ts = {0, 1000000L}; nanosleep(&ts, NULL); }
    }
    CHECK(entered == 3, "pool stop: all three workers are inside the backend");
    uint64_t t0 = mono_ns();
    nvn_vk_pipe_demand_stop();
    uint64_t dt_ms = (mono_ns() - t0) / 1000000ull;
    CHECK(dt_ms < 1500, "pool stop: bounded wait returns while builds are held");
    CHECK(!nvn_vk_pipe_demand_quiescent(), "pool stop: quiescent stays false while builds are held");
    gate_release();
    CHECK(wait_demand_idle(4000), "pool stop: pool settles after builds are released");
    CHECK(nvn_vk_pipe_demand_worker_count() == 0, "pool stop: worker count returns to zero");
}

struct dedup_kick_arg { const nvn_gpu_pipe_desc *d; const uint8_t *id; };
static void *dedup_kick_main(void *opaque) {
    struct dedup_kick_arg *a = opaque;
    nvn_gpu_pipe cached;
    nvn_vk_pipe_demand_kick(a->d, a->id, &cached);
    return NULL;
}

// 并发去重：两条线程同时 kick 同一个键，只建一次、dedup 至少 +1。
// 变异档 nodup（kick 不再走 FOLLOW）：会建两次，本用例红。
static void t_dedup_concurrent(void) {
    g_test_workers = 2;
    nvn_vk_pipe_demand_stop(); nvn_vk_pipe_demand_start();   // start 会重置统计：基线必须在它之后取
    struct nvn_pipe_demand_stats s0; nvn_vk_pipe_demand_stats(&s0);
    CHECK(nvn_vk_pipe_demand_worker_count() == 2, "dedup: two workers running");
    pthread_mutex_lock(&g_mu); g_gate_hold = 1; g_gate_entered = 0; pthread_mutex_unlock(&g_mu);
    nvn_gpu_pipe_desc D; memset(&D, 0, sizeof D);
    D.st[0].sh = (nvn_gpu_shader)(uintptr_t)0xE1; D.prim = 31;
    uint8_t id[32]; set_ident(id, 0xE1);
    struct dedup_kick_arg a = { &D, id };
    pthread_t th[2];
    for (int i = 0; i < 2; i++) CHECK(pthread_create(&th[i], NULL, dedup_kick_main, &a) == 0, "dedup: kicker thread");
    for (int i = 0; i < 2; i++) pthread_join(th[i], NULL);
    gate_release();
    nvn_gpu_pipe out; char why[128];
    CHECK(nvn_vk_pipe_demand_wait(&D, id, 4000, &out, why, sizeof why) == 0 && out != NULL, "dedup: key builds");
    struct nvn_pipe_demand_stats s1; nvn_vk_pipe_demand_stats(&s1);    CHECK(s1.built - s0.built == 1, "dedup: one pipeline built for two concurrent kicks");
    CHECK(s1.dedup - s0.dedup >= 1, "dedup: the second kicker is deduplicated");
    nvn_vk_pipe_demand_stop();
    CHECK(wait_demand_idle(3000), "dedup: pool stops cleanly");
}
static int run_suite(void) {
    const enum demand_event safe_order[] = {DEMAND_WORKER_START, DEMAND_WORKER_EXIT, DEMAND_BACKEND_RELEASE};
    const enum demand_event release_while_active[] = {DEMAND_WORKER_START, DEMAND_BACKEND_RELEASE, DEMAND_WORKER_EXIT};
    const enum demand_event overlapping_workers[] = {DEMAND_WORKER_START, DEMAND_WORKER_START, DEMAND_WORKER_EXIT, DEMAND_WORKER_EXIT};
    CHECK(demand_events_safe(safe_order, sizeof safe_order / sizeof safe_order[0]), "synthetic normal lifecycle order accepted");
    CHECK(!demand_events_safe(release_while_active, sizeof release_while_active / sizeof release_while_active[0]), "synthetic negative control rejects backend release while worker active");
    CHECK(!demand_events_safe(overlapping_workers, sizeof overlapping_workers / sizeof overlapping_workers[0]), "synthetic negative control rejects overlapping workers");
    nvn_vk_pipe_demand_test_set_on(0);
    uint64_t denials_before = nvn_vk_pipe_demand_test_start_lock_denials();
    int logs_before = atomic_load_explicit(&g_start_denial_logs, memory_order_acquire);
    nvn_vk_pipe_demand_start();
    CHECK(nvn_vk_pipe_demand_test_start_lock_denials() == denials_before, "disabled demand start does not count a lock denial");
    CHECK(atomic_load_explicit(&g_start_denial_logs, memory_order_acquire) == logs_before, "disabled demand start emits no diagnostic");
    CHECK(nvn_vk_pipe_demand_worker_count() == 0, "disabled demand start creates no worker");
    nvn_vk_pipe_demand_test_set_on(1);
    int start_lifecycle_lock = nvn_vk_pipe_demand_test_lock_lifecycle();
    CHECK(start_lifecycle_lock == 0, "test holds g_stop_mu for denied-start case");
    if (start_lifecycle_lock == 0) {
        struct start_thread_arg start_arg = {0};
        pthread_t start_thread;
        if (pthread_create(&start_thread, NULL, start_thread_main, &start_arg) == 0) {
            uint64_t deadline = mono_ns() + 1000000000ull;
            while (!atomic_load_explicit(&start_arg.done, memory_order_acquire) && mono_ns() < deadline) {
                struct timespec ts = {0, 1000000L}; nanosleep(&ts, NULL);
            }
            CHECK(atomic_load_explicit(&start_arg.done, memory_order_acquire), "enabled start returns while g_stop_mu remains held");
            CHECK(nvn_vk_pipe_demand_test_start_lock_denials() == denials_before + 1, "denied start increments the monotonic counter once");
            CHECK(atomic_load_explicit(&g_start_denial_logs, memory_order_acquire) == logs_before + 1, "denied start emits one warning");
            CHECK(strstr(g_last_start_denial, "g_stop_mu trylock failed rc=") != NULL && strstr(g_last_start_denial, "denials=1") != NULL, "warning names the failed trylock and cumulative count");
            CHECK(nvn_vk_pipe_demand_worker_count() == 0, "denied start creates no worker");
            nvn_vk_pipe_demand_test_unlock_lifecycle();
            pthread_join(start_thread, NULL);
        } else {
            CHECK(0, "create enabled start contention thread");
            nvn_vk_pipe_demand_test_unlock_lifecycle();
        }
    }
    memset(&g_prog, 0, sizeof g_prog);
    g_prog.sh[0] = (nvn_gpu_shader)(uintptr_t)0x1;
    g_prog.sh[1] = (nvn_gpu_shader)(uintptr_t)0x2;
    nvn_vk_pipe_demand_start();
    CHECK(nvn_vk_pipe_demand_worker_count() == want_workers(), "initial worker is tracked");
    uint8_t idA[32], idC[32], idB[32];
    set_ident(idA, 0xA1); set_ident(idC, 0xC3); set_ident(idB, 0xB2);

    nvn_gpu_pipe_desc a; memset(&a, 0, sizeof a);
    a.st[0].sh = g_prog.sh[0]; a.st[1].sh = g_prog.sh[1]; a.prim = 3;

    nvn_gpu_pipe cached = NULL, out = NULL; char why[128];
    int k = nvn_vk_pipe_demand_kick(&a, idA, &cached);
    CHECK(k == NVK_DEMAND_PENDING, "first kick PENDING");
    int w = nvn_vk_pipe_demand_wait(&a, idA, 2000, &out, why, sizeof why);
    CHECK(w == 0 && out != NULL, "wait READY after background build");
    nvn_gpu_pipe hit = NULL;
    CHECK(nvn_gpu_pipe_lookup(&a, &hit) && hit == out, "lookup hits after build");
    CHECK(nvn_vk_pipe_demand_state(&a, idA, &cached) == NVK_DEMAND_READY, "state READY");

    k = nvn_vk_pipe_demand_kick(&a, idA, &cached);
    CHECK(k == NVK_DEMAND_READY && cached == out, "second kick READY from cache");

    // P0 回归：状态/格式相同、仅着色器句柄不同 → 必须各自建，不得串管线
    nvn_gpu_pipe outA = out;
    nvn_gpu_pipe_desc c; memset(&c, 0, sizeof c);
    c.st[0].sh = (nvn_gpu_shader)(uintptr_t)0x11; c.st[1].sh = (nvn_gpu_shader)(uintptr_t)0x22; c.prim = 3;
    int kc = nvn_vk_pipe_demand_kick(&c, idC, &cached);
    CHECK(kc == NVK_DEMAND_PENDING, "diff-shader rename kick must be PENDING (not READY from A)");
    nvn_gpu_pipe outC = NULL;
    int wc = nvn_vk_pipe_demand_wait(&c, idC, 2000, &outC, why, sizeof why);
    CHECK(wc == 0 && outC != NULL, "diff-shader wait READY");
    CHECK(outC != outA, "P0: diff-shader recipe must NOT get A's pipeline object");

    // 后台失败
    pthread_mutex_lock(&g_mu); g_fail_next = 1; g_has_inst = 0; pthread_mutex_unlock(&g_mu);
    nvn_gpu_pipe_desc b; memset(&b, 0, sizeof b); b.st[0].sh = g_prog.sh[0]; b.prim = 4;
    k = nvn_vk_pipe_demand_kick(&b, idB, &cached);
    CHECK(k == NVK_DEMAND_PENDING, "fail-recipe kick PENDING");
    w = nvn_vk_pipe_demand_wait(&b, idB, 2000, &out, why, sizeof why);
    CHECK(w == 2 && out == NULL, "wait FAILED with why");
    CHECK(why[0] != 0, "failure carries why text");

    nvn_vk_pipe_demand_stop();
    CHECK(nvn_vk_pipe_demand_quiescent(), "completed worker is reaped after stop");
    struct nvn_pipe_demand_stats settled;
    nvn_vk_pipe_demand_stats(&settled);
    CHECK(settled.published >= 2, "published stats retain admitted pipeline results");
    CHECK(nvn_vk_pipe_demand_worker_count() == 0, "completed worker count returns to zero");

    nvn_vk_pipe_demand_start();
    CHECK(nvn_vk_pipe_demand_worker_count() == want_workers(), "new generation owns one worker");
    nvn_gpu_pipe_desc slow; memset(&slow, 0, sizeof slow);
    slow.st[0].sh = (nvn_gpu_shader)(uintptr_t)0x31; slow.prim = 8;
    uint8_t idSlow[32]; set_ident(idSlow, 0xD4);
    pthread_mutex_lock(&g_mu); g_fail_next = 0; g_has_inst = 0; g_gate_hold = 1; g_gate_entered = 0; pthread_mutex_unlock(&g_mu);
    k = nvn_vk_pipe_demand_kick(&slow, idSlow, &cached);
    CHECK(k == NVK_DEMAND_PENDING, "gated build kick PENDING");
    if (!wait_gate_entered(2000)) {
        CHECK(0, "fake build reaches deterministic gate");
        gate_release(); nvn_vk_pipe_demand_stop(); wait_demand_idle(2000);
        printf("%s (%d failures, builds=%d)\n", fails ? "RED" : "GREEN", fails, g_build_calls);
        return fails ? 1 : 0;
    }

    nvn_gpu_pipe_desc queued; memset(&queued, 0, sizeof queued);
    queued.st[0].sh = (nvn_gpu_shader)(uintptr_t)0x32; queued.prim = 9;
    uint8_t idQueued[32]; set_ident(idQueued, 0xD5);
    CHECK(nvn_vk_pipe_demand_kick(&queued, idQueued, &cached) == NVK_DEMAND_PENDING, "second gated job queues behind active build");

    struct nvn_pipe_demand_stats before, after;
    nvn_vk_pipe_demand_stats(&before);
    CHECK(before.published == 0, "held generation has no published result before stop");
    int lifecycle_lock = nvn_vk_pipe_demand_test_lock_lifecycle();
    CHECK(lifecycle_lock == 0, "test holds lifecycle serialization for busy-stop case");
    uint64_t busy_stop_start = mono_ns();
    nvn_vk_pipe_demand_stop();
    uint64_t busy_stop_ms = (mono_ns() - busy_stop_start) / 1000000ull;
    if (lifecycle_lock == 0) nvn_vk_pipe_demand_test_unlock_lifecycle();
    CHECK(busy_stop_ms < 100, "stop publishes without waiting when lifecycle serialization is busy");
    CHECK(nvn_vk_pipe_demand_kick(&queued, idQueued, &cached) == NVK_DEMAND_NONE, "busy-lifecycle stop closes queue admission");

    struct stop_thread_arg stop_arg = {0};
    pthread_t stop_thread;
    uint64_t stop_ms;
    if (pthread_create(&stop_thread, NULL, stop_thread_main, &stop_arg) == 0) {
        int lifecycle_busy = wait_lifecycle_busy(1000);
        CHECK(lifecycle_busy, "first stop holds lifecycle serialization while waiting");
        if (lifecycle_busy) {
            uint64_t call_start = mono_ns();
            nvn_vk_pipe_demand_stop();
            CHECK((mono_ns() - call_start) / 1000000ull < 100, "concurrent stop returns instead of queuing another bounded wait");
            call_start = mono_ns();
            nvn_vk_pipe_demand_start();
            CHECK((mono_ns() - call_start) / 1000000ull < 100, "start returns instead of queuing behind stop");
            CHECK(!nvn_vk_pipe_demand_quiescent(), "quiescence is conservatively false while lifecycle serialization is busy");
            CHECK(nvn_vk_pipe_demand_worker_count() >= 1 && nvn_vk_pipe_demand_worker_count() <= want_workers(), "concurrent lifecycle calls keep the live workers");
        }
        for (int i = 0; i < 1200 && !atomic_load_explicit(&stop_arg.done, memory_order_acquire); i++) {
            struct timespec ts = {0, 1000000L}; nanosleep(&ts, NULL);
        }
        CHECK(atomic_load_explicit(&stop_arg.done, memory_order_acquire), "first bounded stop completes while build is held");
        pthread_join(stop_thread, NULL);
        stop_ms = stop_arg.elapsed_ms;
    } else {
        CHECK(0, "create concurrent stop thread");
        uint64_t stop_start = mono_ns();
        nvn_vk_pipe_demand_stop();
        stop_ms = (mono_ns() - stop_start) / 1000000ull;
    }
    CHECK(stop_ms >= 450 && stop_ms < 1000, "stop stays bounded near 500ms while build is held");
    CHECK(!nvn_vk_pipe_demand_quiescent(), "timed-out stop retains live worker ownership");
    CHECK(nvn_vk_pipe_demand_worker_count() >= 1 && nvn_vk_pipe_demand_worker_count() <= want_workers(), "timed-out workers remain active");
    int builds_held = g_build_calls;
    nvn_vk_pipe_demand_start();
    CHECK(nvn_vk_pipe_demand_worker_count() >= 1 && nvn_vk_pipe_demand_worker_count() <= want_workers(), "refused restart does not create extra workers");
    nvn_vk_pipe_demand_stats(&after);
    CHECK(!nvn_vk_pipe_demand_quiescent(), "start cannot replace the live worker");
    CHECK(after.kicked == before.kicked && g_build_calls == builds_held, "refused restart does not reset state or create a worker");
    CHECK(nvn_vk_pipe_demand_kick(&slow, idSlow, &cached) == NVK_DEMAND_NONE, "stop keeps queue admission closed");

    pthread_mutex_lock(&g_mu); g_fail_next = 1; pthread_mutex_unlock(&g_mu);
    gate_release();
    CHECK(wait_demand_idle(2000), "late worker completion is joined before close/restart");
    pthread_mutex_lock(&g_mu); int builds_after_stop = g_build_calls; pthread_mutex_unlock(&g_mu);
    CHECK(builds_after_stop == builds_held, "busy-lifecycle stop discards queued work behind active build");
    CHECK(nvn_vk_pipe_demand_worker_count() == 0, "reaped worker count returns to zero");
    nvn_vk_pipe_demand_stats(&after);
    CHECK(after.published == before.published, "stopped generation does not increment published stats");
    CHECK(nvn_vk_pipe_demand_state(&slow, idSlow, &cached) == NVK_DEMAND_NONE, "stopped generation does not publish late result");
    nvn_vk_pipe_demand_stop();
    nvn_vk_pipe_demand_start();
    CHECK(nvn_vk_pipe_demand_worker_count() == want_workers(), "restarted generation owns one worker");
    nvn_gpu_pipe_desc next; memset(&next, 0, sizeof next);
    next.st[0].sh = (nvn_gpu_shader)(uintptr_t)0x41; next.prim = 9;
    uint8_t idNext[32]; set_ident(idNext, 0xE5);
    pthread_mutex_lock(&g_mu); g_fail_next = 0; pthread_mutex_unlock(&g_mu);
    CHECK(nvn_vk_pipe_demand_kick(&next, idNext, &cached) == NVK_DEMAND_PENDING, "restart after reap accepts new work");
    CHECK(nvn_vk_pipe_demand_wait(&next, idNext, 2000, &out, why, sizeof why) == 0 && out != NULL, "restarted generation builds successfully");
    nvn_vk_pipe_demand_stop();
    CHECK(nvn_vk_pipe_demand_quiescent(), "final stop leaves no joinable worker");
    CHECK(nvn_vk_pipe_demand_worker_count() == 0, "final stop leaves no active worker");
    printf("%s (%d failures, builds=%d)\n", fails ? "RED" : "GREEN", fails, g_build_calls);
    return fails ? 1 : 0;
}

int main(int argc, char **argv) {
    if (argc > 1) {   // 变异档：只跑指定用例（改坏版本必须让它红）
        if (!strcmp(argv[1], "priority")) t_priority();
        else if (!strcmp(argv[1], "pool_stop")) t_pool_stop();
        else if (!strcmp(argv[1], "dedup")) t_dedup_concurrent();
        else { printf("unknown case %s\n", argv[1]); return 2; }
        printf("case %s: %s (%d failures)\n", argv[1], fails ? "RED" : "GREEN", fails);
        return fails ? 1 : 0;
    }
    g_test_workers = -1;
    int rc = run_suite();
    t_priority();
    t_pool_stop();
    t_dedup_concurrent();
    g_test_workers = -1;
    printf("extra cases: %s (%d failures total)\n", fails ? "RED" : "GREEN", fails);
    return (rc || fails) ? 1 : 0;
}
