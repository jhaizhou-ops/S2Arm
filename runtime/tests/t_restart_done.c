// 重启完成登记点（runtime/src/session.c s2a_session_on_restart_done）：壳登记一次，不管谁发起进程内重启，新局起来后都调一次。
//   起因：普查总表 #23 刺客信条 艾吉奥合集，游戏 ExecuteProgram 同序号经服务层发起重启，iOS 重启首帧屏障原先只在设置页回调里放，
//   游戏发起的重启不经那里，新局停在屏障后。
// 链真实 session.c（控制 / 退休两条线程、s2a_host_restart 受理、restart_session 全序列），其余各子系统的逐局复位用返回成功的桩，
//   重建入口 s2a_host_rebuild 按用例返回成功 / 失败。期望全部手算：
//   ① 登记后，请求方带回调重启：登记点调 1 次（新代号 2），先于请求回调；请求回调 0
//   ② 再重启、请求方不带回调（同游戏发起时服务层以外的发起方）：登记点再调 1 次（代号 3）——登记跨重启存活，不随会话复位清
//   ③ 登记 NULL 后重启：登记点不调，请求回调照常 0
//   ④ 重新登记、重建失败：登记点不调；请求回调 -1；日志有「【红】进程内重启失败」
#include "../src/native.h"
#include "s2a_session.h"
#include <dispatch/dispatch.h>
#include <fcntl.h>
#include <time.h>

uint64_t now_ns(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (uint64_t)t.tv_sec * 1000000000 + t.tv_nsec; }
// 各子系统逐局停止 / 复位：本单测只验登记点，全部按成功
int s2a_svc_park_all(int ms) { (void)ms; return 0; }
int s2a_gate_inflight(void) { return 0; }
void s2a_gate_stop_begin(void) {}
void s2a_gate_process_exit(void) {}
int s2a_thread_stop_all(int ms) { (void)ms; return 0; }
int s2a_thread_restart_supported(void) { return 1; }
int s2a_gate_session_reset(void) { return 0; }
int s2a_thread_session_reset(void) { return 0; }
int s2a_window_session_reset(void) { return 0; }
int s2a_window_ok(void) { return 1; }
int s2a_fps_session_stop(void) { return 0; }
int s2a_widen_session_stop(void) { return 0; }
int s2a_ap_session_stop(void) { return 0; }
int s2a_fps_session_reset(void) { return 0; }
void s2a_cpatch_session_reset(void) {}
int s2a_widen_session_reset(void) { return 0; }
void s2a_loader_session_reset(void) {}
void s2a_mem_session_reset(void) {}
void s2a_direct_host_session_reset(void) {}
int s2a_ap_session_reset(void) { return 0; }
int s2a_far_session_reset(void) { return 0; }
void s2a_alt_session_reset(void) {}
void s2a_hud_session_reset(void) {}
void s2a_os_session_reset(void) {}
void s2a_thread_terminal_stop_point(void) {}
void s2a_loader_abort_boot_inputs(void) {}
void s2a_cpatch_abort_boot_inputs(void) {}
void s2a_nro_abort_boot_inputs(void) {}
void s2a_widen_abort_boot_inputs(void) {}
void s2a_fps_abort_boot_inputs(void) {}
int s2a_loader_begin_boot(void) { return 0; }
int s2a_loader_abort_boot(void) { return 0; }
void s2a_loader_commit_boot(void) {}
// s2a_host_restart 按名（dlsym）找的生命周期导出
int S2A_ShutdownSession(void) { return 0; }
int S2A_InitSession(void) { return 0; }
int S2A_CancelSessionWaits(unsigned generation) { (void)generation; return 0; }
int S2A_StopFailedSession(unsigned generation) { (void)generation; return 0; }
int s2a_graphics_request_stop(void) { return 0; }
int s2a_graphics_shutdown_session(void) { return 0; }
int s2a_graphics_restart_check(void) { return 0; }
void s2a_track_bind_host(void) {}
static int g_rebuild_rc;
int s2a_host_rebuild(void) { return g_rebuild_rc; }

static dispatch_semaphore_t g_done, g_obs_done;
static _Atomic int g_seq, g_obs_n, g_obs_seq, g_cb_n, g_cb_seq, g_cb_rc;
static _Atomic unsigned g_obs_gen;
static void observer(unsigned generation) { g_obs_n++; g_obs_gen = generation; g_obs_seq = ++g_seq; dispatch_semaphore_signal(g_obs_done); }
static void request_cb(int result, const char *detail, void *context) {
    (void)detail; (void)context; g_cb_n++; g_cb_rc = result; g_cb_seq = ++g_seq; dispatch_semaphore_signal(g_done);
}
static int bad;
#define WANT(c, ...) do { int ok_ = (c); printf("%s ", ok_ ? "✓" : "✗"); printf(__VA_ARGS__); printf("（%s）\n", #c); if (!ok_) bad++; } while (0)
static void reset_counts(void) { while (!dispatch_semaphore_wait(g_done, DISPATCH_TIME_NOW)) {} while (!dispatch_semaphore_wait(g_obs_done, DISPATCH_TIME_NOW)) {} g_seq = g_obs_n = g_obs_seq = g_cb_n = g_cb_seq = 0; g_cb_rc = 99; g_obs_gen = 0; }
// 发起重启；with_cb = 0 时没有请求回调，等登记点（登记点不来就超时，按不符计）
static int restart(int with_cb) {
    reset_counts();
    int rc = s2a_host_restart(with_cb ? request_cb : NULL, NULL);
    if (rc) return rc;
    return dispatch_semaphore_wait(with_cb ? g_done : g_obs_done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) ? -100 : 0;
}

int main(void) {
    char logpath[] = "/tmp/t_restart_done.XXXXXX";
    int lfd = mkstemp(logpath); if (lfd < 0) return 2;
    g_s2a_logfd = lfd;
    g_done = dispatch_semaphore_create(0); g_obs_done = dispatch_semaphore_create(0);
    if (s2a_session_prepare() || s2a_session_running(1)) { printf("✗ 会话准备失败\n"); return 1; }

    s2a_session_on_restart_done(observer);
    int rc = restart(1);
    WANT(rc == 0 && g_cb_n == 1 && g_cb_rc == 0, "① 设置页式（带回调）重启受理并完成：请求回调 1 次、结果 0");
    WANT(g_obs_n == 1 && g_obs_gen == 2, "① 登记点调 1 次、新代号 2（实测 %d 次、代号 %u）", (int)g_obs_n, (unsigned)g_obs_gen);
    WANT(g_obs_seq && g_obs_seq < g_cb_seq, "① 登记点先于请求回调（先放屏障、后回设置页）");

    rc = restart(0);
    WANT(rc == 0 && g_obs_n == 1 && g_obs_gen == 3, "② 不带请求回调的重启（游戏发起同类）：登记点仍调 1 次、代号 3（实测 rc %d、%d 次、代号 %u）", rc, (int)g_obs_n, (unsigned)g_obs_gen);

    s2a_session_on_restart_done(NULL);
    rc = restart(1);
    WANT(rc == 0 && g_cb_rc == 0 && g_obs_n == 0, "③ 取消登记后重启：登记点 0 次、请求回调照常 0（实测 %d 次）", (int)g_obs_n);

    s2a_session_on_restart_done(observer);
    g_rebuild_rc = -1;
    rc = restart(1);
    usleep(50000);
    WANT(rc == 0 && g_cb_n == 1 && g_cb_rc == -1, "④ 重建失败：请求回调 1 次、结果 -1（实测 %d 次、%d）", (int)g_cb_n, (int)g_cb_rc);
    WANT(g_obs_n == 0, "④ 重建失败：登记点不调（实测 %d 次）", (int)g_obs_n);
    char log[16384]; ssize_t n = pread(lfd, log, sizeof log - 1, 0); log[n > 0 ? n : 0] = 0;
    WANT(strstr(log, "【红】进程内重启失败") != NULL, "④ 重建失败：日志报红「进程内重启失败」");
    unlink(logpath);
    printf("%s t_restart_done：%d 处不符（共 8 项）\n", bad ? "✗" : "✓", bad);
    fflush(stdout);
    _exit(bad != 0);   // 控制 / 退休线程是进程级常驻，不 join
}
