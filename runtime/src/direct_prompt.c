// 通用 → 直连「就绪提示重启」的判定（接口与规则见 runtime/include/s2a_direct_prompt.h；时机口径 docs/设计_双轨.md §11.1）。
// 只在前端主线程上调 poll / answer / menu；save_committed 从 FS 服务线程来，只写一个原子时间戳。
#include "native.h"
#include "s2a_gfx_mode.h"
#include "s2a_direct_prompt.h"
#include "s2a_session.h"
#include <dlfcn.h>
#include <stdatomic.h>
#include <time.h>

void *s2a_nvn_bootstrap_entry(void) __attribute__((weak_import));   // 直连图形层（graphics/nvn）；没链 = 不能切直连，也就不提示
// 单调秒数；单测用强定义覆盖
__attribute__((weak)) double s2a_dprompt_now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }

static _Atomic long long g_commit_ms = -1;   // 最近一次存档提交（单调毫秒），-1 = 本次运行还没有
static _Atomic unsigned g_commits;
__attribute__((visibility("default"), used)) void s2a_dprompt_save_committed(void) {   // C# 按符号名取（services InputPump）
    atomic_store(&g_commit_ms, (long long)(s2a_dprompt_now() * 1000)); atomic_fetch_add(&g_commits, 1);
}

static double g_t0 = -1, g_next_check, g_ready_at = -1;
static int g_done;          // 本次运行已提示过（或判定不该提示）
static int g_next = -1;     // 本次运行里玩家选过的下次模式；-1 = 没选过，按文件
static double g_quiet, g_wait;
static double env_s(const char *name, double dflt) { const char *e = getenv(name); return e && *e ? atof(e) : dflt; }

static int next_mode(void) { int m = s2a_mode_next(); return g_next >= 0 ? g_next : m; }
static int ready_now(void) {
    if (g_ready_at < 0 && s2a_direct_ready()) { g_ready_at = s2a_dprompt_now(); LOG("提示重启：直连已就绪，等存档时机（存档后静 %.0f 秒；最多等 %.0f 秒改普通提示）", g_quiet, g_wait); }
    return g_ready_at >= 0;
}

int s2a_dprompt_poll(void) {
    double now = s2a_dprompt_now();
    if (!s2a_gfx_mode_settled()) return S2A_DPROMPT_NONE;   // 宿主还没定数据目录（说明页等资源包 / 预热刚起）：模式没落定，不判
    if (g_t0 < 0) {   // 第一次：判这次运行要不要管提示；阈值可用环境变量调（实测 / 截图用），缺省按 §11.1
        g_t0 = now; g_next_check = now + 10;
        g_quiet = env_s("S2A_DPROMPT_QUIET_S", 30); g_wait = env_s("S2A_DPROMPT_WAIT_S", 900);
        int next = next_mode(); const char *why = NULL;
        if (!s2a_nvn_bootstrap_entry) why = "本宿主没链直连图形层";
        else if (s2a_gfx_mode() == S2A_GFX_DIRECT) why = "本次已是直连";
        else if (next == S2A_GFX_DIRECT) why = "下次起局已定为直连";
        if (why) { g_done = 1; LOG("提示重启：本次不提示（%s）", why); }
    }
    if (g_done) return S2A_DPROMPT_NONE;
    if (g_ready_at < 0) {   // 没就绪：开局 10 秒后查一次，之后每 60 秒（通用模式边玩边收集着色器，就绪会在局中变成是）
        if (now < g_next_check) return S2A_DPROMPT_NONE;
        g_next_check = now + 60;
        if (!ready_now()) return S2A_DPROMPT_NONE;
    }
    long long c = atomic_load(&g_commit_ms);
    double since = c < 0 ? -1 : now - c / 1000.0;
    // 刚存过档：最近一次提交后静了 quiet 秒（多给 5 秒余量：前台每秒问一次，进后台那几秒问不到就等下一次存档）
    if (since >= g_quiet && since <= g_quiet + 5) { g_done = 1; LOG("提示重启：刚存过档（%.0f 秒前，本次第 %u 次提交）→ 提示", since, atomic_load(&g_commits)); return S2A_DPROMPT_SAVED; }
    if (now - g_ready_at >= g_wait) { g_done = 1; LOG("提示重启：就绪 %.0f 秒没等到存档时机 → 普通提示", now - g_ready_at); return S2A_DPROMPT_PLAIN; }
    return S2A_DPROMPT_NONE;
}

int s2a_dprompt_answer(int accept) {
    g_done = 1;
    if (!accept) { LOG("提示重启：玩家没选切换，本次运行不再提示"); return 0; }
    int r = s2a_mode_request(S2A_GFX_DIRECT, "用户确认");
    if (!r) g_next = S2A_GFX_DIRECT;
    return r;
}

int s2a_dprompt_menu(void) {
    if (!s2a_nvn_bootstrap_entry) return -1;
    if (next_mode() == S2A_GFX_DIRECT) return S2A_GFX_GENERIC;
    if (g_t0 < 0) { g_quiet = env_s("S2A_DPROMPT_QUIET_S", 30); g_wait = env_s("S2A_DPROMPT_WAIT_S", 900); }
    return s2a_gfx_mode() == S2A_GFX_DIRECT || ready_now() ? S2A_GFX_DIRECT : -1;
}

int s2a_dprompt_menu_pick(void) {
    int m = s2a_dprompt_menu(); if (m < 0) return -1;
    int r = s2a_mode_request(m, m == S2A_GFX_DIRECT ? "设置入口：切到高性能模式" : "设置入口：切回通用模式");
    if (!r) { g_next = m; g_done = 1; }   // 手动选过就不再弹提示
    return r;
}

int s2a_save_atomic_poll(void) {
    static int looked, warned; static int (*state)(void);
    if (warned || s2a_host_session_state() != S2A_SESSION_RUNNING) return 0;
    if (!looked) { looked = 1; state = (int (*)(void))dlsym(RTLD_DEFAULT, "S2A_SaveAtomicState"); }
    int bits = state ? state() : 0;
    if (!bits) return 0;
    warned = 1;
    LOG("存档：不能原子提交（原因位 %d：1 没登记原语 / 2 卷不能克隆或原子交换 / 4 工作目录准备失败），提示玩家", bits);
    return bits;
}
