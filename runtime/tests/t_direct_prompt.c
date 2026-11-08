// 提示重启判定单测（runtime/include/s2a_direct_prompt.h；时机口径 docs/设计_双轨.md §11.1）：期望值按口径手写。
// 时间、图形模式、mode 文件、就绪判定都换成桩；每例 fork 一个子进程，状态机的静态量从零开始。
#include "../src/native.h"
#include "s2a_gfx_mode.h"
#include "s2a_direct_prompt.h"
#include "s2a_session.h"
#include <sys/wait.h>
#include <unistd.h>

static double g_now; static int g_mode, g_file_next, g_ready, g_req = -1, g_req_n, g_ready_calls;
double s2a_dprompt_now(void) { return g_now; }
void *s2a_nvn_bootstrap_entry(void) { return NULL; }
int s2a_gfx_mode(void) { return g_mode; }
static int g_settled = 1; int s2a_gfx_mode_settled(void) { return g_settled; }
int s2a_mode_next(void) { return g_file_next; }
int s2a_mode_request(int mode, const char *reason) { (void)reason; g_req = mode; g_req_n++; g_file_next = mode; return 0; }
int s2a_direct_ready(void) { g_ready_calls++; return g_ready; }
// 存档原子提交状态（审计 P2-45）：服务层导出 S2A_SaveAtomicState 的桩，被测代码按 dlsym 取到它；会话状态桩
static int g_atomic, g_atomic_calls, g_session = S2A_SESSION_RUNNING;
__attribute__((visibility("default"), used)) int S2A_SaveAtomicState(void) { g_atomic_calls++; return g_atomic; }
int s2a_host_session_state(void) { return g_session; }

// 从 g_now 起每秒问一次，到 until 秒（含）；返回第一次非 NONE 的结果，*at = 那一刻
static int run_until(double until, double *at) {
    for (; g_now <= until; g_now += 1) { int r = s2a_dprompt_poll(); if (r) { *at = g_now; return r; } }
    *at = -1; return S2A_DPROMPT_NONE;
}
static int fails;
#define CASE(name, body) do { pid_t p = fork(); if (!p) { body; _exit(0); } int st; waitpid(p, &st, 0); \
    if (!WIFEXITED(st) || WEXITSTATUS(st)) { fails++; printf("✗ %s\n", name); } else printf("  ✓ %s\n", name); } while (0)
#define WANT(cond) do { if (!(cond)) { printf("    不符：%s（行 %d）\n", #cond, __LINE__); _exit(1); } } while (0)

int main(void) {
    unsetenv("S2A_DPROMPT_QUIET_S"); unsetenv("S2A_DPROMPT_WAIT_S");
    double at;
    // 就绪，100 秒时存档：静 30 秒 → 第 130 秒弹「刚存过档」；之后不再弹
    CASE("存档后静 30 秒弹一次", { g_ready = 1; WANT(run_until(99, &at) == 0); s2a_dprompt_save_committed();
        WANT(run_until(200, &at) == S2A_DPROMPT_SAVED && at == 130); WANT(run_until(2000, &at) == 0); });
    // 静的 30 秒里又存了一次：从第二次算起
    CASE("连续存档从最后一次算", { g_ready = 1; run_until(99, &at); s2a_dprompt_save_committed(); run_until(120, &at);
        s2a_dprompt_save_committed(); WANT(run_until(300, &at) == S2A_DPROMPT_SAVED && at == 151); });
    // 一直不存档：就绪（第 10 秒查到）后 900 秒 → 第 910 秒普通提示
    CASE("15 分钟等不到存档改普通提示", { g_ready = 1; WANT(run_until(2000, &at) == S2A_DPROMPT_PLAIN && at == 910); });
    // 就绪前存的档不算「刚存过」：存档在第 5 秒，就绪在第 70 秒才查到（10 秒查一次否，之后每 60 秒）
    CASE("就绪前很久的存档不算", { g_ready = 0; s2a_dprompt_save_committed(); run_until(69, &at); g_ready = 1;
        WANT(run_until(800, &at) == 0); WANT(run_until(2000, &at) == S2A_DPROMPT_PLAIN && at == 970); });
    // 没就绪：查就绪的次数 = 第 10 秒一次 + 之后每 60 秒（10, 70, …, 550 共 10 次），从不弹
    CASE("没就绪不弹、每 60 秒查一次", { g_ready = 0; WANT(run_until(599, &at) == 0); WANT(g_ready_calls == 10); });
    // 模式没落定（iOS 宿主还没定数据目录：说明页等资源包时）：不判、不查就绪；第 51 秒落定后从那时起算 → 第 61 秒查到就绪，再 900 秒（第 961 秒）普通提示
    CASE("模式没落定不判，落定后从那时起算", { g_settled = 0; g_ready = 1; WANT(run_until(50, &at) == 0); WANT(g_ready_calls == 0);
        g_settled = 1; WANT(run_until(2000, &at) == S2A_DPROMPT_PLAIN && at == 961); });
    CASE("本次已是直连不弹", { g_ready = 1; g_mode = S2A_GFX_DIRECT; s2a_dprompt_save_committed(); WANT(run_until(2000, &at) == 0); WANT(g_ready_calls == 0); });
    CASE("下次已定直连不弹", { g_ready = 1; g_file_next = S2A_GFX_DIRECT; WANT(run_until(2000, &at) == 0); });
    CASE("同意写直连", { g_ready = 1; WANT(run_until(2000, &at) == S2A_DPROMPT_PLAIN); WANT(s2a_dprompt_answer(1) == 0);
        WANT(g_req == S2A_GFX_DIRECT && g_req_n == 1); WANT(s2a_dprompt_menu() == S2A_GFX_GENERIC); });
    CASE("拒绝不写、不再弹", { g_ready = 1; WANT(run_until(2000, &at) == S2A_DPROMPT_PLAIN); WANT(s2a_dprompt_answer(0) == 0);
        WANT(g_req_n == 0); s2a_dprompt_save_committed(); WANT(run_until(4000, &at) == 0); });
    // 设置入口：没就绪不给；就绪给「切到高性能」，点了写直连、不再弹提示；下次已定直连给「切回通用」，点了写通用
    CASE("设置入口：没就绪不给", { g_ready = 0; WANT(s2a_dprompt_menu() == -1); WANT(s2a_dprompt_menu_pick() == -1 && g_req_n == 0); });
    CASE("设置入口：就绪切高性能", { g_ready = 1; WANT(s2a_dprompt_menu() == S2A_GFX_DIRECT); WANT(s2a_dprompt_menu_pick() == 0 && g_req == S2A_GFX_DIRECT);
        WANT(s2a_dprompt_menu() == S2A_GFX_GENERIC); WANT(run_until(2000, &at) == 0); });
    CASE("设置入口：直连中切回通用", { g_mode = S2A_GFX_DIRECT; g_file_next = S2A_GFX_DIRECT; WANT(s2a_dprompt_menu() == S2A_GFX_GENERIC);
        WANT(s2a_dprompt_menu_pick() == 0 && g_req == S2A_GFX_GENERIC); WANT(s2a_dprompt_menu() == S2A_GFX_DIRECT); });
    CASE("阈值环境变量", { setenv("S2A_DPROMPT_QUIET_S", "3", 1); setenv("S2A_DPROMPT_WAIT_S", "20", 1); g_ready = 1;
        WANT(run_until(2000, &at) == S2A_DPROMPT_PLAIN && at == 30); });

    // 存档不能原子提交（审计 P2-45，Mac / iOS 同一判定）：会话没跑起来不问服务层；跑起来后一直是 0 不提示；第一次读到非 0 返回原因位，只返回一次
    CASE("存档原子：会话没跑起来不问", { g_session = S2A_SESSION_STARTING; g_atomic = 2; WANT(s2a_save_atomic_poll() == 0); WANT(g_atomic_calls == 0); });
    CASE("存档原子：一直原子不提示", { g_atomic = 0; for (int i = 0; i < 5; i++) WANT(s2a_save_atomic_poll() == 0); WANT(g_atomic_calls == 5); });
    CASE("存档原子：首次非 0 提示一次", { g_atomic = 0; WANT(s2a_save_atomic_poll() == 0); g_atomic = 2; WANT(s2a_save_atomic_poll() == 2);
        g_atomic = 6; WANT(s2a_save_atomic_poll() == 0); WANT(s2a_save_atomic_poll() == 0); });

    if (fails) { printf("✗ t_direct_prompt：%d 例不符\n", fails); return 1; }
    printf("✓ t_direct_prompt：17 例全符\n");
    return 0;
}
