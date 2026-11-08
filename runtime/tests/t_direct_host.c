// 直连模式系统层接点单测（runtime/src/direct_host.c，接口 runtime/include/s2a_direct_host.h）：bash runtime/gate.sh 里自动跑
// 期望手写：① 缺页钩子没登记回 0、登记后原样回钩子结果，重复登记同一个无害，登记第二个不同的钩子 → 报错退出（子进程 SIGABRT）；
//   ② 写前回调直接登记到写跟踪（s2a_track_set_write_prep 收到同一个函数）；③ 崩溃现场 / 资源行回调：没登记时调用无事，登记后各调一次
#include "../src/native.h"
#include "../include/s2a_direct_host.h"
#include <stdio.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>

static void (*g_track_fn)(uint64_t, uint64_t); static int g_track_set;
void s2a_track_set_write_prep(void (*fn)(uint64_t, uint64_t)) { g_track_fn = fn; g_track_set++; }   // 桩：本测不链 graphics/track
int s2a_direct_fault(void *addr, int is_write, void *uctx);
void s2a_direct_wait_dump(void), s2a_direct_res_report(void);

static void *g_mine;
static int h(void *a, int w, void *uc) { (void)uc; return w && a == g_mine; }
static int h_other(void *a, int w, void *uc) { (void)a; (void)w; (void)uc; return 0; }
static void prep(uint64_t a, uint64_t n) { (void)a; (void)n; }
static int g_wd, g_rr, g_normal, g_timeout;
static void summary(int normal) { if (normal) g_normal++; else g_timeout++; }
static void wd(void) { g_wd++; }
static void rr(void) { g_rr++; }

static int bad;
static void check(const char *what, int ok) { printf("%s %s\n", ok ? "✓" : "✗", what); if (!ok) bad++; }

int main(void) {
    char page[64]; g_mine = page + 8;
    check("① 没登记缺页钩子：回 0", s2a_direct_fault(page + 8, 1, NULL) == 0);
    s2a_fault_hook_register(h); s2a_fault_hook_register(h);
    check("① 登记后原样回钩子结果（认领 1 / 别的地址 0 / 读 0），重复登记同一个无害",
          s2a_direct_fault(page + 8, 1, NULL) == 1 && s2a_direct_fault(page + 16, 1, NULL) == 0 && s2a_direct_fault(page + 8, 0, NULL) == 0);
    pid_t c = fork();
    if (c == 0) { freopen("/dev/null", "w", stderr); s2a_fault_hook_register(h_other); _exit(0); }
    int st = 0; waitpid(c, &st, 0);
    check("① 登记第二个不同的钩子 → 报错退出（子进程被 SIGABRT 结束）", WIFSIGNALED(st) && WTERMSIG(st) == SIGABRT);
    s2a_guest_write_prep_register(prep);
    check("② 写前回调直接登记到写跟踪（同一个函数，登记 1 次）", g_track_fn == prep && g_track_set == 1);
    s2a_direct_wait_dump(); s2a_direct_res_report();
    check("③ 没登记时调用无事", g_wd == 0 && g_rr == 0);
    s2a_crash_wait_dump_register(wd); s2a_res_report_register(rr);
    s2a_direct_wait_dump(); s2a_direct_res_report();
    check("③ 登记后各调一次（崩溃现场 1、资源行 1）", g_wd == 1 && g_rr == 1);
    s2a_direct_summary(1); s2a_direct_summary(0);
    check("④ 没登记汇总时无事", g_normal == 0 && g_timeout == 0);
    s2a_direct_summary_register(summary); s2a_direct_summary_register(summary);
    s2a_direct_summary(1); s2a_direct_summary(0);
    check("④ 汇总原样传正常/超时，重复登记同一个无害", g_normal == 1 && g_timeout == 1);
    printf("%s t_direct_host：%d 处不符\n", bad ? "✗" : "✓", bad);
    return bad != 0;
}
