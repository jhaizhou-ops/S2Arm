// Shell -> core session lifecycle. Callbacks run on the control thread.
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    S2A_SESSION_STARTING,
    S2A_SESSION_RUNNING,
    S2A_SESSION_RESTARTING,
    S2A_SESSION_FAILED,
};
typedef void (*s2a_restart_callback)(int result, const char *detail, void *context);
// 0 = accepted, -1 = no running session, -2 = missing lifecycle support,
// -3 = another restart is running. A callback result of 0 means the new guest
// thread has started; it does not certify first frame or game/save acceptance.
// detail is borrowed and valid only during the callback. Never exits the app.
// The old generation has one 10-second host-monotonic retirement deadline.
// Timeout reports failure once and seals rebuilding; an execution worker may
// still own old resources. Failure is not proof that cleanup has completed.
int s2a_host_restart(s2a_restart_callback callback, void *context);
int s2a_host_session_state(void);
// 重启完成登记点（进程级，壳在启动时登记一次；会话复位不清）：任何发起方（设置页 / 游戏 ExecuteProgram /
// 测试开关）的进程内重启，新局起来后都在控制线程上调一次，generation 是新会话代号；失败 / 超时不调（失败已报红）。
// iOS 壳靠它放「重启首帧屏障」（s2a_session_guest_start_prepare 立、s2a_session_guest_start_complete 放）。
// 再登记覆盖上一次；NULL 取消。iPhone 上屏障立着却没人登记 → 报红。
typedef void (*s2a_restart_done_fn)(unsigned generation);
void s2a_session_on_restart_done(s2a_restart_done_fn fn);
// Apple initializes the real stop boundary before inspecting its roster.
// Android reports unsupported; no live/reap join proof is available there.
int s2a_session_rebuild_supported(void);
// Set when the worker starts stopping the old session; cleared before the
// new session initializes. Rejected requests never set this flag.
int s2a_session_stop_requested(void);
unsigned s2a_session_generation(void);
// Prepare the host controller and sole retirement execution thread before any
// managed service starts. Both are process-lifetime owners, not per-request jobs.
// Failure leaves FAILED and does not claim that a session has been stopped.
int s2a_session_prepare(void);
int s2a_session_running(unsigned generation);
// Lock-free notification; never joins/disposes on the service thread. Returns
// 1 for a normal RUNNING error: report/continue, reject restart, allow normal exit.
int s2a_session_service_failed(unsigned generation);
// Zero is reserved for native ordinary host exit, independent of managed owner.
void s2a_session_process_exit(unsigned generation);
// Native-only admission section: retain it until the real guest roster is entered.
int s2a_session_guest_begin(unsigned generation);
void s2a_session_guest_end(int registration_pending);

// iOS lifecycle transitions are serialized with restart admission. A deferred
// transition only records background intent while the old generation retires
// or the replacement guest is being prepared.
enum {
    S2A_SESSION_LIFECYCLE_APPLY,
    S2A_SESSION_LIFECYCLE_DEFERRED,
    S2A_SESSION_LIFECYCLE_TERMINAL,
    S2A_SESSION_LIFECYCLE_BUSY,
};
int s2a_session_background_begin(int on);
void s2a_session_background_end(void);
// Called after provider initialization succeeds and immediately before the
// replacement guest thread is created. Initial startup and macOS are no-ops.
int s2a_session_guest_start_prepare(unsigned generation);
// iOS calls this after it confirms the replacement session is foregrounded.
// A successful rebuild stays held until this gate is released.
int s2a_session_guest_start_complete(uint64_t *t_direct, uint64_t *t_gpu,
                                     uint64_t *t_thread, uint64_t *t_done);

#ifdef __cplusplus
}
#endif
