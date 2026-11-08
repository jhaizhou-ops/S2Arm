// 撑不住就问玩家（11-02 jhz：「帧率检测放宽到30秒，如果持续30秒还维持不住60帧标准（60帧标准也得放宽一点点），就提示是否切换锁30帧。画面同样，
//   最好只宿主识别游戏画面而不是菜单页和过场动画之类的，如果检测到游戏画面持续20秒有满屏幕问题就提示是否退回原生16:9。记住玩家的最后选择，
//   并在 app 设置中可以更改，注意本来就只已经是16:9模式的游戏和本来就60帧的游戏不要弹。最好做成热切换。」）
// 本文件只做判定（纯函数式状态机，单测 runtime/tests/t_qprompt.c 喂时间序列）；每帧由直连上屏调 s2a_qp_present，提示 / 记住选择 / 热切换在 ios/app.m。
//   游戏画面帧：不在放视频（nvn_vpace）、没有过场标记（帧率表 dm_fps_state +4）、与上一帧间隔 < 1 秒（加载 / 暂停 / 切后台不算）、
//     本帧绘制数 ≥ 开局基线 × 3（基线 = 首帧起 10 秒内各帧绘制数的中位数，同自动玩家进局判据：标题 / logo / 读盘页绘制少，局内多）。
//   帧率：游戏画面连续 ≥ 30 秒（中间夹非游戏画面帧就重新起算），最近 30 秒的实际帧率（帧数 ÷ 30）< 55 → 问一次。
//     55 = 60 帧放宽约 8%：帧步撑不住时按 30 帧保持，窗口均值 < 55 即至少约 1/6 时间落在 30 帧；偶发一两次掉帧（几帧 33 ms）不到这个量。
//   满屏：游戏画面帧里满屏判据（内容）报「没铺满」的时长累计 ≥ 20 秒 → 问一次。
//   一律按本局运行时实际生效状态判（总指挥 11-02）：帧率只在 60 帧真在生效（fps.c eff()：有来源、设置开着、没降档）的帧上计时，不生效的帧打断连续段；
//   满屏只在本局画面真放宽了（宽屏核心在生效、不在原比例回退）的帧上累计。本来 60 帧 / 没来源 / 关了 / 本来 16:9 自然不问。
//   每种提示一局最多一次；玩家问过的（记在 App 设置）由调用方 s2a_qp_config 关掉
//   原生 60 帧（总指挥 11-02，jhz 丝之歌关 60 帧照样 60 帧、以为开关没生效）：游戏画面帧里游戏自设交换间隔累计 30 秒都是 1、从没 ≥ 2 → s2a_qp_native60() = 1
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>
#include "s2a_qprompt.h"

#define QP_BASE_NS 10000000000ull   // 开局基线采样 10 秒
#define QP_GAP_NS 1000000000ull     // 两帧间隔 ≥ 1 秒：那一帧不是游戏帧
#define QP_FPS_NS 30000000000ull    // 帧率窗口 30 秒
#define QP_FPS_MIN 55               // 窗口实际帧率 < 55 帧算撑不住
#define QP_N60_DT_NS 20000000ull    // 原生 60 帧判定：游戏画面帧间隔 ≤ 20 ms（≥ 50 帧）才算真按 60 帧在出；更长的记慢帧时长
#define QP_FIT_NS 20000000000ull    // 局内没铺满累计 20 秒
#define QP_RING 4096                // 30 秒窗口最多帧数（120 帧 × 30 秒 = 3600）

static _Atomic int g_fit_want;
static int g_game;   // 上一帧是不是局内游戏画面（s2a_qp_game：档位梯子 runtime/src/qladder_host.c、满屏自检 qprompt_host.c 用同一个判定）   // 满屏判据此刻值得采样（s2a_qp_fit_wanted）：上屏线程写、采样线程读
static struct {
    int ask_fps, ask_fit, asked_fps, asked_fit, slow_seen;   // slow_seen：游戏画面帧里见过游戏自设间隔 ≥ 2（30 帧及以下）
    uint64_t t0, prev, seg0, fit_ns, n60_ns, nslow_ns;   // 游戏画面帧里游戏自设间隔 1 的累计时长：n60_ns 帧间隔 ≤ 20 ms 的、nslow_ns 更长的
    uint32_t base_d[600]; int base_n, base_done; uint32_t base;
    uint64_t ring[QP_RING]; int rh, rn;   // 本段游戏画面帧时刻（环形）
} g;

void s2a_qp_reset(void) { int f = g.ask_fps, w = g.ask_fit; memset(&g, 0, sizeof g); g.ask_fps = f; g.ask_fit = w; atomic_store(&g_fit_want, 0); }
int s2a_qp_fit_wanted(void) { return atomic_load(&g_fit_want); }
int s2a_qp_game(void) { return g_game; }
int s2a_qp_unfit_sample(int kind, int64_t errors_now, int64_t *last) {
    int grew = *last >= 0 && errors_now > *last;   // 首次读（*last < 0）只记基数：开局前的异常不算这一局的画面
    *last = errors_now;
    return grew || (kind >= 1 && kind <= 3);
}
void s2a_qp_config(int ask_fps, int ask_fit) { g.ask_fps = ask_fps; g.ask_fit = ask_fit; }
static int cmpu(const void *a, const void *b) { uint32_t x = *(const uint32_t *)a, y = *(const uint32_t *)b; return x < y ? -1 : x > y; }
uint32_t s2a_qp_base(void) { return g.base_done ? g.base : 0; }
static int g_secs;   // 最近一次触发时的「过去 XX 秒」：帧率 = 这段连续游戏画面的秒数，满屏 = 局内没铺满累计秒数（提示文案用）
int s2a_qp_secs(void) { return g_secs; }

// 原生 60 帧：游戏自设间隔一直是 1，且真按 60 帧出图——按实际帧间隔判，不只看交换间隔（11-02 c1102_v2 八方：间隔一直 1、引擎自己限 30，
//   墙钟 33.3 ms，原先判「原生 60 帧」，设置页把 60 帧开关置灰写「本款原生 60 帧」）。慢帧时长超过 60 帧时长的十分之一就不算（偶发长帧不翻案）
int s2a_qp_native60(void) {
    if (g.slow_seen || (g.nslow_ns >= QP_FPS_NS && g.nslow_ns * 10 > g.n60_ns)) return 0;
    return g.n60_ns >= QP_FPS_NS && g.nslow_ns * 10 <= g.n60_ns ? 1 : -1;
}
int s2a_qp_present(uint64_t now, uint32_t draws, int video, int cutscene, int unfit, int fps_live, int fit_live, int game_itv) {
    if (!g.t0) g.t0 = now;
    uint64_t dt = g.prev ? now - g.prev : 0; g.prev = now;
    g_game = 0;
    if (!g.base_done) {   // 开局 10 秒：只采基线，不判
        if (g.base_n < (int)(sizeof g.base_d / sizeof g.base_d[0])) g.base_d[g.base_n++] = draws;
        if (now - g.t0 < QP_BASE_NS) return 0;
        qsort(g.base_d, (size_t)g.base_n, sizeof g.base_d[0], cmpu); g.base = g.base_d[g.base_n / 2]; g.base_done = 1;
    }
    int game = !video && !cutscene && dt && dt < QP_GAP_NS && draws >= 3 * (g.base ? g.base : 1); g_game = game;
    atomic_store(&g_fit_want, game && fit_live && g.ask_fit && !g.asked_fit);
    if (!game || !fps_live) { g.rn = 0; g.seg0 = 0; }   // 帧率连续段：只认 60 帧在生效的游戏画面帧
    else { if (!g.seg0) g.seg0 = now;
        g.ring[(g.rh + g.rn) % QP_RING] = now; if (g.rn < QP_RING) g.rn++; else g.rh = (g.rh + 1) % QP_RING;
        while (g.rn && now - g.ring[g.rh] > QP_FPS_NS) { g.rh = (g.rh + 1) % QP_RING; g.rn--; } }
    if (!game) return 0;
    if (game_itv >= 2) g.slow_seen = 1; else if (dt <= QP_N60_DT_NS) g.n60_ns += dt; else g.nslow_ns += dt;   // 原生 60 帧判定只看游戏画面帧（菜单 / 读盘页常设间隔 1，不算）
    if (unfit && fit_live) g.fit_ns += dt;
    if (g.ask_fps && !g.asked_fps && g.seg0 && now - g.seg0 >= QP_FPS_NS && g.rn * 1000000000ull < (uint64_t)QP_FPS_MIN * QP_FPS_NS) { g.asked_fps = 1; g_secs = (int)((now - g.seg0) / 1000000000ull); return S2A_QP_FPS; }
    if (g.ask_fit && !g.asked_fit && g.fit_ns >= QP_FIT_NS) { g.asked_fit = 1; atomic_store(&g_fit_want, 0); g_secs = (int)(g.fit_ns / 1000000000ull); return S2A_QP_FIT; }
    return 0;
}
