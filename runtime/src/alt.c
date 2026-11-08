// 同局交替开关（帧率能耗线 10-24，总指挥：塞尔达同包不开开关两局读回就差 10.9 / 16.2 s，场景波动比开关效果大，改成同一局里交替开关比相邻窗口）。
// S2A_ALT=<秒>（缺省不设 = 不交替）：MARK 起算，第 0 段关、第 1 段开、第 2 段关……每段这么多秒。MARK 之前不算任何段（各开关照自己的缺省 / 环境变量）。
// 接这个的开关在热路径上问 s2a_alt_phase()：-1 = 没在交替（照原行为）、0 = 关段、1 = 开段。信号处理里可调（只读原子量与 now_ns()，不加锁不分配）；MARK 初始化不在信号处理里调用。
// 每帧写 frames.tsv 时把相位记进 alt 列（graphics/metal/cs/NxFrames.cs），窗口统计按它分；执行器（tools/dev_run.sh）在每段里护边后采两次整机功耗（pwalt_<k>a / b），tools/alt_report.py 只用段内两次之间的读数。
#include "native.h"
#include <stdatomic.h>

static _Atomic uint64_t g_alt_t0;        // MARK 时刻（纳秒；0 = 还没 MARK）
static _Atomic int64_t g_alt_period = -1; // 每段时长（纳秒；-1 未读环境变量，0 = 不交替）
static uint64_t g_alt_sec;
void s2a_alt_session_reset(void) { atomic_store(&g_alt_t0, 0); }

// 纯函数（单测用）：t0 = 起点，now = 现在，period = 每段时长（均为纳秒）。没起点 / 不交替 → -1；否则段号奇偶（0 关 1 开）
int s2a_alt_phase_at(uint64_t t0, uint64_t now, uint64_t period) {
    if (!t0 || !period || now < t0) return -1;
    return (int)(((now - t0) / period) & 1);
}
static int64_t alt_period(void) {
    int64_t p = atomic_load(&g_alt_period);
    if (p >= 0) return p;
    const char *v = getenv("S2A_ALT"); long s = v && *v ? atol(v) : 0; if (s < 0) s = 0;
    p = s ? (int64_t)((uint64_t)s * 1000000000ull) : 0;
    g_alt_sec = (uint64_t)s; atomic_store(&g_alt_period, p); return p;
}
int s2a_alt_phase(void) {
    int64_t p = atomic_load(&g_alt_period); if (p <= 0) return -1;   // 未读（MARK 时才读）或不交替
    return s2a_alt_phase_at(atomic_load(&g_alt_t0), now_ns(), (uint64_t)p);
}
// MARK 时调（runtime/src/ap_host.c）：记起点，只记第一次
void s2a_alt_mark(void) {
    if (alt_period() <= 0) return;
    uint64_t z = 0;
    if (atomic_compare_exchange_strong(&g_alt_t0, &z, now_ns()))
        LOG("[交替] 起：MARK 起每 %llu 秒一段，第 0 段关、第 1 段开（S2A_ALT）", (unsigned long long)g_alt_sec);
}
