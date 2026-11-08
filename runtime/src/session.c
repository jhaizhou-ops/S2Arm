// 进程内会话重启：每一步有真实完成条件，失败保留尚有读者的资源。
#include "native.h"
#include "s2a_session.h"
#include <dlfcn.h>
#include <stdatomic.h>
#include <setjmp.h>
#if defined(__APPLE__)
#include <TargetConditionals.h>
#include "s2a_gfx_mode.h"
#include <dispatch/dispatch.h>
#endif

static _Thread_local jmp_buf *g_boot_boundary;
void s2a_loader_abort_boot_inputs(void), s2a_cpatch_abort_boot_inputs(void);
void s2a_nro_abort_boot_inputs(void), s2a_widen_abort_boot_inputs(void);
#if defined(__APPLE__)   // fps.c（帧率表）不在安卓源码清单里，安卓没有要清的装载输入
void s2a_fps_abort_boot_inputs(void);
int s2a_loader_begin_boot(void), s2a_loader_abort_boot(void);
void s2a_loader_commit_boot(void);
static void abort_boot_resources(void);
#endif
void s2a_session_abort_boot(void) { if (g_boot_boundary) longjmp(*g_boot_boundary, 1); }
int s2a_session_try_boot(void (*boot)(void *), void *context) {
#if defined(__APPLE__)
    if (g_boot_boundary || s2a_loader_begin_boot()) {
        LOG("【红】装载失败边界需要空的原生会话，未开始新的 boot");
        return -1;
    }
#endif
    jmp_buf boundary;
    if (setjmp(boundary)) {
        g_boot_boundary = NULL;
        // These are thread-local temporary inputs, not published mappings,
        // tables or session owners that may still have readers.
        s2a_loader_abort_boot_inputs(); s2a_cpatch_abort_boot_inputs();
        s2a_nro_abort_boot_inputs(); s2a_widen_abort_boot_inputs();
#if defined(__APPLE__)
        s2a_fps_abort_boot_inputs();
        abort_boot_resources();
#endif
        return -1;
    }
    g_boot_boundary = &boundary;
    boot(context);
    g_boot_boundary = NULL;
#if defined(__APPLE__)
    s2a_loader_commit_boot();
#endif
    return 0;
}

// Generation and phase have one linearization point. A successful start must
// never overwrite a failure from the same (or a retired) service owner.
#define SESSION(gen, state) (((uint64_t)(gen) << 32) | (unsigned)(state))
#define SESSION_EXITING UINT64_C(0x80000000)
// A normal running service error retains main's report-and-continue behavior.
// Keep the error in the same atomic word so a restart cannot race past it.
#define SESSION_REPORTED UINT64_C(0x40000000)
#define SESSION_FLAGS (SESSION_EXITING | SESSION_REPORTED)
static _Atomic uint64_t g_session = SESSION(1, S2A_SESSION_STARTING);
static _Atomic int g_stop_requested;
static _Atomic int g_rebuilding;
static _Atomic int g_control_ready;
static _Atomic int g_retirement_active;
static int g_guest_pending; // protected by g_request_mu
static pthread_mutex_t g_request_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t g_lifecycle_mu = PTHREAD_MUTEX_INITIALIZER;
static int g_lifecycle_transition_active; // protected by g_lifecycle_mu
static int g_restart_guest_gate;          // set after provider init; old guest is already retired
#if defined(__APPLE__) && TARGET_OS_IPHONE
static void (*g_ios_direct_suspend)(int);
static int (*g_ios_direct_guest_start_hold)(void);
static void (*g_ios_gpu_hold)(int, const char *);
#endif
#if defined(__APPLE__)
static int g_lifecycle_background;        // protected by g_lifecycle_mu; Apple lifecycle paths only
static _Atomic int g_prepare_failed, g_retirement_done;   // only the Apple control / retirement path uses them (unused-variable is -Werror on Android)
static dispatch_semaphore_t g_control_event, g_retirement_event, g_retirement_completion;
static pthread_t g_control_thread, g_retirement_thread;
#endif
static s2a_restart_callback g_callback;
static _Atomic(s2a_restart_done_fn) g_restart_done;   // 进程级，不随会话复位
void s2a_session_on_restart_done(s2a_restart_done_fn fn) { atomic_store(&g_restart_done, fn); }
static void *g_context;
static uint64_t g_requested_deadline; // protected by g_request_mu
// One execution owner retains this slot until it has returned from every
// blocking runtime/managed call. A timeout only completes the shell request.
#if defined(__APPLE__)
static struct {
    unsigned generation;
    int state;
    uint64_t deadline;
    const char *detail;
} g_retirement;
#endif
#define RETIREMENT_TIMEOUT_NS UINT64_C(10000000000)
#if defined(__APPLE__)
static const char retirement_timeout[] = "停止旧游戏超时，已取消重启。请完全退出应用后重新打开。";
static const char restart_failed[] = "游戏重启失败，请完全退出应用后重新打开。";
#endif
static int (*g_services_stop)(void), (*g_graphics_stop)(void), (*g_graphics_destroy)(void);
static int (*g_rebuild)(void);
static int (*g_cancel_waits)(unsigned);
void s2a_gate_process_exit(void);

static int exiting(void) { return (atomic_load(&g_session) & SESSION_EXITING) != 0; }
int s2a_host_session_state(void) { return (unsigned)atomic_load(&g_session) & ~(unsigned)SESSION_FLAGS; }
int s2a_session_stop_requested(void) {
    return atomic_load(&g_stop_requested) || exiting() || s2a_host_session_state() == S2A_SESSION_FAILED;
}
unsigned s2a_session_generation(void) { return atomic_load(&g_session) >> 32; }
#if defined(__APPLE__)
static int restarting(unsigned generation) {
    return atomic_load(&g_session) == SESSION(generation, S2A_SESSION_RESTARTING);
}
#endif
static void wake_control(void) {
#if defined(__APPLE__)
    if (atomic_load(&g_control_ready)) {
        dispatch_semaphore_signal(g_control_event);
        dispatch_semaphore_signal(g_retirement_completion);
    }
#endif
}
int s2a_session_running(unsigned generation) {
    uint64_t expected = SESSION(generation, S2A_SESSION_STARTING);
    if (!atomic_compare_exchange_strong(&g_session, &expected, SESSION(generation, S2A_SESSION_RUNNING))) return -1;
    return 0;
}
int s2a_session_service_failed(unsigned generation) {
    uint64_t current = atomic_load(&g_session);
    for (;;) {
        if ((current >> 32) != generation || (current & SESSION_EXITING)) return -1;
        if (((unsigned)current & ~(unsigned)SESSION_FLAGS) == S2A_SESSION_RUNNING) {
            if (!atomic_compare_exchange_weak(&g_session, &current, current | SESSION_REPORTED)) continue;
            return 1; // report only; ordinary timers/exit remain available.
        }
        if ((unsigned)current == S2A_SESSION_FAILED) return 0;
        if (atomic_compare_exchange_weak(&g_session, &current, SESSION(generation, S2A_SESSION_FAILED))) break;
    }
    atomic_store(&g_stop_requested, 1);
    wake_control();
    return 0;
}
void s2a_session_process_exit(unsigned generation) {
    uint64_t current = atomic_load(&g_session);
    do {
        if (generation && (current >> 32) != generation) return;
    } while (!atomic_compare_exchange_weak(&g_session, &current, current | SESSION_EXITING));
    atomic_store(&g_stop_requested, 1);
    s2a_gate_process_exit();
    wake_control();
#if defined(__APPLE__)
    if (atomic_load(&g_control_ready)) dispatch_semaphore_signal(g_retirement_event);
#endif
}
int s2a_session_guest_begin(unsigned generation) {
    pthread_mutex_lock(&g_request_mu);
    uint64_t current = atomic_load(&g_session);
    if ((current >> 32) != generation || s2a_session_stop_requested() ||
        ((unsigned)current != S2A_SESSION_STARTING && (unsigned)current != S2A_SESSION_RESTARTING)) {
        pthread_mutex_unlock(&g_request_mu); return -1;
    }
    g_guest_pending = 1;
    return 0;
}
void s2a_session_guest_end(int registration_pending) {
    g_guest_pending = registration_pending;
    pthread_mutex_unlock(&g_request_mu);
}
void s2a_session_timer_run(unsigned generation, void (*action)(void)) {
    pthread_mutex_lock(&g_request_mu);
    if ((atomic_load(&g_session) & ~SESSION_REPORTED) == SESSION(generation, S2A_SESSION_RUNNING))
        action();
    pthread_mutex_unlock(&g_request_mu);
}

int s2a_svc_park_all(int);
int s2a_gate_inflight(void);
void s2a_gate_stop_begin(void);
int s2a_thread_stop_all(int);
int s2a_thread_restart_supported(void);
int s2a_gate_session_reset(void);
int s2a_thread_session_reset(void);
int s2a_window_session_reset(void);
int s2a_fps_session_stop(void), s2a_widen_session_stop(void), s2a_ap_session_stop(void);
int s2a_fps_session_reset(void);
void s2a_cpatch_session_reset(void);
int s2a_widen_session_reset(void);
void s2a_loader_session_reset(void);
void s2a_mem_session_reset(void);
void s2a_direct_host_session_reset(void);
int s2a_ap_session_reset(void);
int s2a_far_session_reset(void);
void s2a_alt_session_reset(void);
void s2a_hud_session_reset(void);
void s2a_os_session_reset(void);
#if defined(__APPLE__)
static void abort_boot_resources(void) {
    const char *detail = NULL;
    if (s2a_fps_session_reset()) detail = "帧率写入者未退出";
    if (!detail && s2a_widen_session_reset()) detail = "画幅读取者未退出";
    if (!detail) s2a_cpatch_session_reset();
    if (!detail && s2a_gate_session_reset()) detail = "调用门仍有读者或宿主已终局";
    if (!detail && s2a_far_session_reset()) detail = "远端影子内存未归还";
    if (!detail && s2a_window_ok() && s2a_window_session_reset()) detail = "客体窗口预留未恢复";
    if (!detail && s2a_loader_abort_boot()) detail = "模块映射未归还";
    if (detail) {
        LOG("【红】失败装载未能完整回滚：%s；保留尚未释放的所有权，禁止重试", detail);
        return;
    }
    s2a_mem_session_reset();
    LOG("失败装载回滚完成：新局读取者已退出，输入、注册及客体映射已归还；未启动游戏会话");
}
#endif
void s2a_thread_terminal_stop_point(void);
void s2a_guest_freeze(int);
void s2a_clock_catchup(void);

// This is the existing host monotonic clock, never the frozen guest clock.
// Recheck before each new destructive stage and before the generation CAS.
#if defined(__APPLE__)
static const char *retirement_error(unsigned generation) {
    if (exiting()) return "宿主已终局，控制线程停止后续工作";
    if (now_ns() >= g_retirement.deadline) {
        s2a_session_service_failed(generation);
        s2a_gate_stop_begin();
        return retirement_timeout;
    }
    return restarting(generation) ? NULL : "旧会话服务失败，禁止退休资源或重建";
}

int s2a_session_background_begin(int on) {
    pthread_mutex_lock(&g_lifecycle_mu);
    int state = s2a_host_session_state();
    if (state == S2A_SESSION_FAILED) {
        pthread_mutex_unlock(&g_lifecycle_mu);
        return S2A_SESSION_LIFECYCLE_TERMINAL;
    }
    g_lifecycle_background = on != 0;
    if (state == S2A_SESSION_RESTARTING || g_restart_guest_gate) {
        pthread_mutex_unlock(&g_lifecycle_mu);
        return S2A_SESSION_LIFECYCLE_DEFERRED;
    }
    if (g_lifecycle_transition_active) {
        pthread_mutex_unlock(&g_lifecycle_mu);
        return S2A_SESSION_LIFECYCLE_BUSY;
    }
    g_lifecycle_transition_active = 1;
    pthread_mutex_unlock(&g_lifecycle_mu);
    return S2A_SESSION_LIFECYCLE_APPLY;
}

void s2a_session_background_end(void) {
    pthread_mutex_lock(&g_lifecycle_mu);
    g_lifecycle_transition_active = 0;
    pthread_mutex_unlock(&g_lifecycle_mu);
}

int s2a_session_guest_start_prepare(unsigned generation) {
#if defined(__APPLE__) && TARGET_OS_IPHONE
    if (s2a_host_session_state() != S2A_SESSION_RESTARTING || generation != s2a_session_generation()) return -1;

    int direct_mode = s2a_gfx_mode() == S2A_GFX_DIRECT;
    void (*direct_suspend)(int) = (void (*)(int))dlsym(RTLD_DEFAULT, "s2a_direct_suspend");
    int (*direct_guest_start_hold)(void) = (int (*)(void))dlsym(RTLD_DEFAULT, "s2a_direct_guest_start_hold");
    void (*gpu_hold)(int, const char *) = (void (*)(int, const char *))dlsym(RTLD_DEFAULT, "nxgal_gpu_hold");
    if (!gpu_hold || (direct_mode && (!direct_suspend || !direct_guest_start_hold))) {
        LOG("【红】重启首帧屏障缺少当前图形模式的真实 GPU hold 导出");
        return -1;
    }

    pthread_mutex_lock(&g_lifecycle_mu);
    if (s2a_host_session_state() != S2A_SESSION_RESTARTING || generation != s2a_session_generation() || g_restart_guest_gate) {
        pthread_mutex_unlock(&g_lifecycle_mu);
        return -1;
    }
    g_ios_direct_suspend = direct_suspend;
    g_ios_direct_guest_start_hold = direct_guest_start_hold;
    g_ios_gpu_hold = gpu_hold;
    g_restart_guest_gate = 1;
    pthread_mutex_unlock(&g_lifecycle_mu);

    // Providers have completed their per-session initialization. Keep the
    // startup hold through guest registration and UIKit's foreground decision.
    if (direct_mode && g_ios_direct_guest_start_hold() != 0) return -1;
    guest_clock_freeze_for(1, 1);
    s2a_guest_freeze(1);
    g_ios_gpu_hold(1, "重启首帧屏障");
    LOG("iOS 重启：provider 已就绪，guest 首启前时钟/线程/GPU hold 已建立");
#else
    (void)generation;
#endif
    return 0;
}

int s2a_session_guest_start_complete(uint64_t *t_direct, uint64_t *t_gpu,
                                     uint64_t *t_thread, uint64_t *t_done) {
#if defined(__APPLE__) && TARGET_OS_IPHONE
    int catchup = 0;
    int released = 0;
    pthread_mutex_lock(&g_lifecycle_mu);
    if (g_restart_guest_gate && s2a_host_session_state() == S2A_SESSION_RUNNING && !g_lifecycle_background) {
        // Release only after UIKit has confirmed that the app is foregrounded.
        // These operations only open gates; no retirement or GPU drain runs here.
        if (g_ios_direct_suspend) g_ios_direct_suspend(0);
        if (t_direct) *t_direct = now_ns();
        g_ios_gpu_hold(0, "重启完成");
        if (t_gpu) *t_gpu = now_ns();
        s2a_guest_freeze(0);
        if (t_thread) *t_thread = now_ns();
        guest_clock_freeze_for(1, 0);
        if (t_done) *t_done = now_ns();
        catchup = 1;
        released = 1;
        g_restart_guest_gate = 0;
    } else if (g_restart_guest_gate && s2a_host_session_state() == S2A_SESSION_RUNNING && g_lifecycle_background) {
        // The app is successfully running in the background; keep all holds
        // until the next foreground transition.
        g_restart_guest_gate = 0;
    }
    pthread_mutex_unlock(&g_lifecycle_mu);
    if (catchup) s2a_clock_catchup();
    return released;
#endif
    (void)t_direct; (void)t_gpu; (void)t_thread; (void)t_done;
    return 0;
}

static int restart_guest_publish_running(unsigned generation) {
    pthread_mutex_lock(&g_lifecycle_mu);
    uint64_t expected = SESSION(generation, S2A_SESSION_RESTARTING);
    if (!atomic_compare_exchange_strong(&g_session, &expected, SESSION(generation, S2A_SESSION_RUNNING))) {
        pthread_mutex_unlock(&g_lifecycle_mu);
        return -1;
    }
    pthread_mutex_unlock(&g_lifecycle_mu);
    return 0;
}

static int stop_helpers(void) {
    int result = s2a_fps_session_stop();
    result |= s2a_widen_session_stop();
    result |= s2a_ap_session_stop();
    return result;
}
#endif

// Only native guest terminal paths call this, after leaving managed code.
// A cancellation result may make the old SDK call Break/ExitProcess. That
// cannot turn an accepted in-process restart into the ordinary app _exit.
void s2a_session_park_guest_end(const char *why) {
    int state = s2a_host_session_state();
    if (state != S2A_SESSION_RESTARTING && state != S2A_SESSION_FAILED) return;
    if (atomic_load(&g_rebuilding)) {
        if (!s2a_session_service_failed(s2a_session_generation())) {
            s2a_gate_stop_begin();
            LOG("【红】重建期间客体终止：%s，保留现场，不退出宿主", why);
        }
    }
    for (;;) { s2a_thread_terminal_stop_point(); usleep(1000); }
}

// No managed callback, guest join or resource retirement runs under request_mu.
struct stop_progress {
    unsigned generation;
    int quiesce_attempted, guest_join_attempted, native_quiesced;
    int services_retired, failed_managed_attempted, failed_managed_joined;
    const char *native_detail, *managed_detail;
};

#if defined(__APPLE__)
static const char *quiesce_once(struct stop_progress *progress) {
    pthread_mutex_lock(&g_request_mu);
    int pending = g_guest_pending;
    pthread_mutex_unlock(&g_request_mu);
    if (exiting()) return "宿主终局，控制线程停止后续工作";
    if (pending) return "游戏主线程尚未确认进入 roster，未能证明停稳，保留资源";
    atomic_store(&g_stop_requested, 1);
    const char *detail = NULL;
    int (*cancel)(unsigned) = (int (*)(unsigned))dlsym(RTLD_DEFAULT, "S2A_CancelSessionWaits");
    int (*graphics_stop)(void) = (int (*)(void))dlsym(RTLD_DEFAULT, "s2a_graphics_request_stop");
    if (!cancel || !graphics_stop) return "缺少真实取消/图形停止导出，尚未停稳，保留资源";
    if (cancel(s2a_session_generation())) return "取消本代服务等待失败，尚未停稳，保留资源";
    if (exiting()) return "取消后宿主已终局，控制线程停止后续工作";
    s2a_svc_park_all(0);
    if (graphics_stop()) detail = "图形等待未能停止，保留当前会话资源";
    if (exiting()) return "图形停止后宿主已终局，控制线程停止后续工作";
    if (!detail && s2a_svc_park_all(5000)) detail = "仍有服务调用未返回，未释放游戏内存";
    if (!detail) {
        s2a_gate_stop_begin();
        progress->guest_join_attempted = 1;
        if (s2a_thread_stop_all(5000)) detail = "仍有游戏线程未安全退出，未释放游戏内存";
    }
    if (!detail && s2a_gate_inflight()) detail = "guest join 后服务在途计数非零，保留会话";
    if (exiting()) return "客体停止后宿主已终局，控制线程停止后续工作";
    if (!detail && stop_helpers())
        detail = "宿主辅助线程未能退出，保留游戏内存";
    return detail;
}

static const char *quiesce(struct stop_progress *progress) {
    if (!progress->quiesce_attempted) {
        progress->quiesce_attempted = 1;
        progress->native_detail = quiesce_once(progress);
        progress->native_quiesced = progress->native_detail == NULL;
    }
    return progress->native_detail;
}

static const char *join_failed_services(struct stop_progress *progress) {
    if (progress->services_retired) return NULL;
    if (progress->failed_managed_attempted) return progress->managed_detail;
    progress->failed_managed_attempted = 1;
    int (*stop)(unsigned) = (int (*)(unsigned))dlsym(RTLD_DEFAULT, "S2A_StopFailedSession");
    progress->failed_managed_joined = stop && stop(progress->generation) == 0;
    progress->managed_detail = progress->failed_managed_joined ? NULL : "失败会话 Horizon 入口线程未能全部 join，保留资源";
    return progress->managed_detail;
}

static int failure_stop_pending(const struct stop_progress *progress) {
    return !progress->quiesce_attempted ||
        (progress->native_quiesced && !progress->services_retired && !progress->failed_managed_attempted);
}

static void stop_failed(struct stop_progress *progress) {
    const char *detail = quiesce(progress);
    if (!detail && !exiting()) detail = join_failed_services(progress);
    s2a_gate_stop_begin();
    if (exiting()) return;
    if (detail) LOG("【红】会话 %u FAILED，尚未停稳：%s（native_join_attempted=%d native_quiesced=%d failed_managed_attempted=%d）",
        progress->generation, detail, progress->guest_join_attempted, progress->native_quiesced, progress->failed_managed_attempted);
    else if (progress->services_retired)
        LOG("会话 %u FAILED：客体与 Horizon 入口线程此前已 join，服务已严格退休；保留其余资源，未重建", progress->generation);
    else LOG("会话 %u FAILED：客体与 Horizon 入口线程已停止并 join；未处置音频/服务/图形/内存资源，未重建", progress->generation);
}
#endif

#if defined(__APPLE__)   // 进程内重建只在苹果路径（安卓 s2a_session_rebuild_supported() = 0）
static const char *restart_session(unsigned *generation, struct stop_progress *progress) {
    unsigned old = *generation;
    const char *detail = retirement_error(old);
    if (!detail) detail = quiesce(progress);
    if (!detail) detail = retirement_error(old);
    if (!detail) {
        if (g_services_stop()) detail = "服务会话关闭失败，未释放游戏内存";
        else progress->services_retired = 1;
    }
    if (!detail) detail = retirement_error(old);
    if (!detail && g_graphics_destroy()) detail = "图形资源回收失败，未重建游戏";
    if (!detail) detail = retirement_error(old);
    if (!detail && s2a_fps_session_reset()) detail = "帧率逐局状态未能清理，未重建游戏";
    if (!detail) detail = retirement_error(old);
    if (!detail && s2a_widen_session_reset()) detail = "画幅逐局状态未能清理，未重建游戏";
    if (!detail) detail = retirement_error(old);
    if (!detail && s2a_ap_session_reset()) detail = "自动输入逐局状态未能清理，未重建游戏";
    if (!detail) detail = retirement_error(old);
    if (!detail) s2a_cpatch_session_reset();
    if (!detail) detail = retirement_error(old);
    if (!detail) s2a_alt_session_reset();
    if (!detail) detail = retirement_error(old);
    if (!detail) s2a_hud_session_reset();
    if (!detail) detail = retirement_error(old);
    if (!detail) s2a_direct_host_session_reset();
    if (!detail) detail = retirement_error(old);
    if (!detail && s2a_gate_session_reset()) detail = "原生调用门仍有活动对象，未重建游戏";
    if (!detail) detail = retirement_error(old);
    if (!detail && s2a_thread_session_reset()) detail = "原生线程仍有活动对象，未重建游戏";
    if (!detail) detail = retirement_error(old);
    if (!detail && s2a_far_session_reset()) detail = "远端影子内存未能退休，未重建游戏";
    if (!detail) detail = retirement_error(old);
    if (!detail && s2a_window_session_reset()) detail = "无法重建游戏地址窗口";
    if (!detail) detail = retirement_error(old);
    if (!detail) s2a_mem_session_reset();
    if (!detail) detail = retirement_error(old);
    if (!detail) s2a_loader_session_reset();
    if (!detail) detail = retirement_error(old);
    if (!detail) s2a_os_session_reset();
    if (!detail) detail = retirement_error(old);
    if (!detail) {
        // Only now have old guests, service callbacks and graphics retired.
        // This CAS also disarms the old-generation deadline in the controller.
        uint64_t expected = SESSION(old, S2A_SESSION_RESTARTING);
        if (old == UINT32_MAX || exiting() ||
            !atomic_compare_exchange_strong(&g_session, &expected, SESSION(old + 1, S2A_SESSION_RESTARTING))) {
            detail = "旧会话失败、宿主终局或代际耗尽，禁止启动新局";
        } else {
            *generation = old + 1;
            *progress = (struct stop_progress){.generation = *generation};
#if defined(__APPLE__)
            dispatch_semaphore_signal(g_retirement_completion);
#endif
            atomic_store(&g_rebuilding, 1);
            atomic_store(&g_stop_requested, 0);
            if (g_rebuild()) detail = "新会话启动失败，请查看应用日志";
        }
    }
    if (!detail && restart_guest_publish_running(*generation))
        detail = "新游戏线程在重建期间终止，请查看应用日志";
    atomic_store(&g_rebuilding, 0);
    if (detail) {
        s2a_session_service_failed(*generation);
        LOG("【红】进程内重启失败：%s", detail);
        // Reuse the old native join result even when strict managed retirement
        // failed before Horizon.Stop. Never start a second native reaper here.
        stop_failed(progress);
        s2a_gate_stop_begin();
    }
    return detail;
}

static void *retirement_worker(void *unused) {
    (void)unused; pthread_setname_np("s2a-会话退休");
    struct stop_progress progress = {0};
    for (;;) {
        dispatch_semaphore_wait(g_retirement_event, DISPATCH_TIME_FOREVER);
        if (atomic_load(&g_prepare_failed) || exiting()) return NULL;
        if (!atomic_load(&g_retirement_active)) continue;
        unsigned generation = g_retirement.generation;
        if (progress.generation != generation) progress = (struct stop_progress){.generation = generation};
        const char *detail = NULL;
        if (g_retirement.state == S2A_SESSION_RESTARTING) {
            detail = restart_session(&generation, &progress);
        } else if (g_retirement.state == S2A_SESSION_FAILED) {
            if (failure_stop_pending(&progress)) stop_failed(&progress);
            detail = "服务会话异步失败，请查看原始异常";
        }
        g_retirement.detail = detail;
        atomic_store(&g_retirement_done, 1);
        dispatch_semaphore_signal(g_retirement_completion);
        // Do not touch the slot after publication. The controller may reuse
        // it only after this result, never merely after a timeout callback.
    }
}

static void restart_done_notify(void) {
    s2a_restart_done_fn done = atomic_load(&g_restart_done);
    if (done) { done(s2a_session_generation()); return; }
    pthread_mutex_lock(&g_lifecycle_mu);
    int held = g_restart_guest_gate;
    pthread_mutex_unlock(&g_lifecycle_mu);
    if (held) LOG("【红】进程内重启完成，但壳层没登记重启完成回调（s2a_session_on_restart_done）：重启首帧屏障无人放开，新局停在屏障后");
}

static void *control_worker(void *unused) {
    (void)unused; pthread_setname_np("s2a-会话控制");
    for (;;) {
        dispatch_semaphore_wait(g_control_event, DISPATCH_TIME_FOREVER);
        if (atomic_load(&g_prepare_failed) || exiting()) return NULL;
        pthread_mutex_lock(&g_request_mu);
        uint64_t current = atomic_load(&g_session);
        s2a_restart_callback callback = g_callback; void *context = g_context;
        uint64_t deadline = g_requested_deadline;
        g_callback = NULL; g_context = NULL; g_requested_deadline = 0;
        pthread_mutex_unlock(&g_request_mu);
        if (exiting()) return NULL;
        int state = (unsigned)current;
        // Only an accepted restart owns retirement. Initial failure exits via
        // host_main; ordinary running errors never dispatch destructive work.
        if (!deadline) continue;
        if (state != S2A_SESSION_RESTARTING && state != S2A_SESSION_FAILED) continue;
        unsigned generation = current >> 32;
        if (!deadline) deadline = now_ns() + RETIREMENT_TIMEOUT_NS;
        g_retirement.generation = generation;
        g_retirement.state = state;
        g_retirement.deadline = deadline;
        g_retirement.detail = NULL;
        atomic_store(&g_retirement_done, 0);
        atomic_store(&g_retirement_active, 1);
        dispatch_semaphore_signal(g_retirement_event);
        int deadline_reported = 0;
        while (!atomic_load(&g_retirement_done)) {
            if (exiting()) return NULL;
            uint64_t now = now_ns();
            // The native generation CAS is the old retirement's completion
            // point. It races against this same-generation FAILED CAS; a late
            // worker cannot reopen admission or boot after the timeout wins.
            if (!deadline_reported && now >= deadline && s2a_session_generation() == generation) {
                if (!s2a_session_service_failed(generation)) {
                    s2a_gate_stop_begin();
                    if (callback && !exiting()) { callback(-1, retirement_timeout, context); callback = NULL; }
                    LOG("【红】会话 %u 退休总等待超过 10 秒：结果已失败；执行线程仍持有资源，未宣称停稳", generation);
                }
                deadline_reported = 1;
            }
            if (callback && !exiting() && s2a_host_session_state() == S2A_SESSION_FAILED) {
                callback(-1, restart_failed, context); callback = NULL;
            }
            dispatch_time_t wait = DISPATCH_TIME_FOREVER;
            if (!deadline_reported && s2a_session_generation() == generation && now < deadline)
                wait = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(deadline - now));
            dispatch_semaphore_wait(g_retirement_completion, wait);
        }
        const char *detail = g_retirement.detail;
        atomic_store(&g_retirement_active, 0);
        if (exiting()) return NULL;
        // 重启完成登记点先于本次请求的回调：放屏障与发起方无关（设置页 / 游戏 ExecuteProgram 走同一处）；
        //   iOS 壳两者都派回主线程，先放屏障、后回设置页，与原设置页回调里的先后一致
        if (!detail) restart_done_notify();
        if (callback) callback(detail ? -1 : 0, detail ? detail : "新游戏会话已启动（尚不代表首帧/存档验收）", context);
    }
}
#endif

int s2a_session_rebuild_supported(void) {
#if defined(__APPLE__)
    return s2a_thread_restart_supported();
#else
    static atomic_flag said = ATOMIC_FLAG_INIT;
    if (!atomic_flag_test_and_set(&said))
        LOG("【红】安卓不提供进程内重建，服务失败走进程退出（runtime.c 收尾）");
    return 0;
#endif
}

int s2a_session_prepare(void) {
    // The managed InitSession caller already owns _lifecycle. Once prepared,
    // never invert that lock with the timer's request_mu -> ordinary shutdown.
    if (exiting() || s2a_host_session_state() == S2A_SESSION_FAILED) return -1;
    if (atomic_load(&g_control_ready)) return 0;
    pthread_mutex_lock(&g_request_mu);
    if (exiting() || s2a_host_session_state() == S2A_SESSION_FAILED) { pthread_mutex_unlock(&g_request_mu); return -1; }
    if (atomic_load(&g_control_ready)) { pthread_mutex_unlock(&g_request_mu); return 0; }
    int rc = -1;
#if defined(__APPLE__)
    g_control_event = dispatch_semaphore_create(0);
    g_retirement_event = dispatch_semaphore_create(0);
    g_retirement_completion = dispatch_semaphore_create(0);
    int execution_started = 0, execution_joined = 1, execution_join_error = 0;
    if (g_control_event && g_retirement_event && g_retirement_completion) {
        pthread_attr_t attr; rc = pthread_attr_init(&attr);
        if (!rc) {
            rc = pthread_attr_setstacksize(&attr, 8u << 20);
            if (!rc) {
                rc = pthread_create(&g_retirement_thread, &attr, retirement_worker, NULL);
                execution_started = !rc;
            }
            if (!rc) rc = pthread_create(&g_control_thread, &attr, control_worker, NULL);
            pthread_attr_destroy(&attr);
            // Both process-lifetime threads stay joinable and own their
            // handles; no new worker is allocated after a service fails.
            if (!rc) atomic_store(&g_control_ready, 1);
        }
    }
    if (rc) {
        atomic_store(&g_prepare_failed, 1);
        if (execution_started) {
            dispatch_semaphore_signal(g_retirement_event);
            execution_join_error = pthread_join(g_retirement_thread, NULL);
            execution_joined = execution_join_error == 0;
        }
        if (execution_joined) {
            if (g_control_event) dispatch_release(g_control_event);
            if (g_retirement_event) dispatch_release(g_retirement_event);
            if (g_retirement_completion) dispatch_release(g_retirement_completion);
            g_control_event = g_retirement_event = g_retirement_completion = NULL;
        }
    }
#endif
    pthread_mutex_unlock(&g_request_mu);
    if (rc) {
        s2a_session_service_failed(s2a_session_generation());
#if defined(__APPLE__)
        if (execution_join_error) LOG("【红】准备失败后的执行线程 join 失败 %d，保留线程和信号量所有权", execution_join_error);
#endif
        LOG("【红】会话控制/执行线程准备失败 %d：FAILED，未起服务/guest，未宣称停稳", rc);
    }
    return rc ? -1 : 0;
}

int s2a_host_restart(s2a_restart_callback callback, void *context) {
    if (pthread_mutex_trylock(&g_request_mu)) return -3;
    int state = s2a_host_session_state();
    if (!atomic_load(&g_control_ready) || exiting()) { pthread_mutex_unlock(&g_request_mu); return -2; }
    if (atomic_load(&g_session) & SESSION_REPORTED) { pthread_mutex_unlock(&g_request_mu); return -1; }
    if (state != S2A_SESSION_RUNNING) {
        pthread_mutex_unlock(&g_request_mu);
        return state == S2A_SESSION_RESTARTING ? -3 : -1;
    }
    if (atomic_load(&g_retirement_active)) { pthread_mutex_unlock(&g_request_mu); return -3; }
    // 这些诊断会话持有运行中断点/串行重放状态，未提供会话析构。
    // 先拒绝，再保持原会话运行；不能在已经清内存后才发现缺少支持。
    const char *diagnostics[] = {"S2A_DET", "S2A_DET_REC", "S2A_DET_PLAY", "S2A_DIAG_DELAY", "S2A_DIAG_STAMP", "S2A_DIAG_DUMP", "S2A_WORKGROUP"};
    for (unsigned i = 0; i < sizeof diagnostics / sizeof *diagnostics; i++) {
        const char *v = getenv(diagnostics[i]);
        if (v && *v && strcmp(v, "0")) { LOG("【红】进程内重启：诊断会话 %s 不支持重建", diagnostics[i]); pthread_mutex_unlock(&g_request_mu); return -2; }
    }
    g_services_stop = (int (*)(void))dlsym(RTLD_DEFAULT, "S2A_ShutdownSession");
    g_rebuild = (int (*)(void))dlsym(RTLD_DEFAULT, "s2a_host_rebuild");
    void *services_start = dlsym(RTLD_DEFAULT, "S2A_InitSession");
    g_cancel_waits = (int (*)(unsigned))dlsym(RTLD_DEFAULT, "S2A_CancelSessionWaits");
    g_graphics_stop = (int (*)(void))dlsym(RTLD_DEFAULT, "s2a_graphics_request_stop");
    g_graphics_destroy = (int (*)(void))dlsym(RTLD_DEFAULT, "s2a_graphics_shutdown_session");
    int (*check)(void) = (int (*)(void))dlsym(RTLD_DEFAULT, "s2a_graphics_restart_check");
    void *track_bind = dlsym(RTLD_DEFAULT, "s2a_track_bind_host");
    if (!g_rebuild || !g_services_stop || !services_start || !g_cancel_waits || !g_graphics_stop || !g_graphics_destroy || !check || !track_bind) {
        LOG("【红】进程内重启：缺少生命周期导出 rebuild=%d services_stop=%d services_start=%d cancel=%d graphics_stop=%d graphics_destroy=%d graphics_check=%d track_bind=%d",
            g_rebuild != NULL, g_services_stop != NULL, services_start != NULL, g_cancel_waits != NULL,
            g_graphics_stop != NULL, g_graphics_destroy != NULL, check != NULL, track_bind != NULL);
        pthread_mutex_unlock(&g_request_mu); return -2;
    }
    if (!s2a_thread_restart_supported()) {
        LOG("【红】进程内重启：缺少客体线程安全退出边界");
        pthread_mutex_unlock(&g_request_mu); return -2;
    }
    int graphics_error = check();
    if (graphics_error) {
        LOG("【红】进程内重启：图形会话当前不可退休 (%d)", graphics_error);
        pthread_mutex_unlock(&g_request_mu); return -2;
    }
    g_callback = callback; g_context = context;
    g_requested_deadline = now_ns() + RETIREMENT_TIMEOUT_NS;
    unsigned generation = s2a_session_generation();
    pthread_mutex_lock(&g_lifecycle_mu);
    if (g_lifecycle_transition_active) {
        pthread_mutex_unlock(&g_lifecycle_mu);
        g_callback = NULL; g_context = NULL; g_requested_deadline = 0;
        pthread_mutex_unlock(&g_request_mu); return -3;
    }
    uint64_t expected = SESSION(generation, S2A_SESSION_RUNNING);
    if (!atomic_compare_exchange_strong(&g_session, &expected, SESSION(generation, S2A_SESSION_RESTARTING))) {
        pthread_mutex_unlock(&g_lifecycle_mu);
        g_callback = NULL; g_context = NULL; g_requested_deadline = 0;
        pthread_mutex_unlock(&g_request_mu); return -1;
    }
    g_restart_guest_gate = 0;
    pthread_mutex_unlock(&g_lifecycle_mu);
    pthread_mutex_unlock(&g_request_mu);
    wake_control();
    return 0;
}
