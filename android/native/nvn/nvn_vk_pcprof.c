// 采样剖析（诊断，debug.s2a.pcprof=1）：按时间给绘制线程取样，回答“这 20 ms 花在哪些函数”。
//
// 为什么需要它：逐笔打点（fd_stamp）在本机每次 clock_gettime 约 250–300 ns，一笔绘制有
// 20 多个打点，仅打点开销就有 ~6.7 µs/笔（实测 perf_timing=1 时 us/draw 45.3、关闭 38.6），
// 而且它只能给出“阶段”粒度，分不出外壳、派发与本模块之外的调用。采样剖析不改被采样的代码，
// 也不进入每笔路径：只在目标线程上定时发 SIGPROF，处理函数把 PC 记进环形数组，
// 摊还到 present 上汇总打印。
//
// 口径：POSIX 定时器 + SIGEV_THREAD_ID 只采“发起 present 的那个线程”，间隔 200 µs；
// 每个样本按 dladdr 的 DSO 基址归一成偏移（本模块的 .so 内偏移可以离线用 llvm-symbolizer
// 还原成函数名，静态函数没有导出符号）。样本只统计、不改变任何运行状态。
#include <android/log.h>
#include <dlfcn.h>
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/system_properties.h>
#include <time.h>
#include <ucontext.h>
#include <unistd.h>

#define PCPROF_TAG "S2Arm"
#define PCPROF_LOG(...) __android_log_print(ANDROID_LOG_INFO, PCPROF_TAG, __VA_ARGS__)
#define PCPROF_CAP 16384u
#define PCPROF_TOP 24

struct pcprof_sample { unsigned tid; unsigned long pc; unsigned long lr; };
static struct pcprof_sample g_pc[PCPROF_CAP];
static volatile unsigned g_pc_n;      // 处理函数只自增它；写满就不再记（不覆盖，避免撕裂）
static int g_pc_atomic_cap = PCPROF_CAP;
static timer_t g_pc_timer;
static int g_pc_timer_live;
static int g_pc_tid;
static unsigned g_pc_drops;

// 处理函数里只做：取 PC、把 (tid, pc) 写进环形数组、自增计数。不取锁、不分配、不打日志。
static void pcprof_sig(int sig, siginfo_t *si, void *ctx) {
    (void)sig; (void)si;
    if (!ctx) return;
#if defined(__aarch64__)
    unsigned long pc = (unsigned long)((ucontext_t *)ctx)->uc_mcontext.pc;
    // x30 = 调用点的返回地址：据此可以回答“这个 memcpy/memset 是谁调的”，
    // 只看 PC 只能知道“时间花在 libc 的拷贝循环里”。
    unsigned long lr = (unsigned long)((ucontext_t *)ctx)->uc_mcontext.regs[30];
#elif defined(__arm__)
    unsigned long pc = (unsigned long)((ucontext_t *)ctx)->uc_mcontext.arm_pc;
    unsigned long lr = (unsigned long)((ucontext_t *)ctx)->uc_mcontext.arm_lr;
#else
    unsigned long pc = 0, lr = 0;
#endif
    unsigned n = g_pc_n;
    if (n >= (unsigned)g_pc_atomic_cap) { g_pc_drops++; return; }
    g_pc[n].tid = (unsigned)syscall(SYS_gettid);
    g_pc[n].pc = pc;
    g_pc[n].lr = lr;
    g_pc_n = n + 1;
}

static int pcprof_enabled(void) {
    static int v = -1;
    if (v < 0) {
        char b[64] = {0};
        __system_property_get("debug.s2a.pcprof", b);
        v = (b[0] && atoi(b)) ? 1 : 0;
    }
    return v;
}

// present 每帧调一次（绘制线程）。负责：首次启动、线程换了重启、每 64 帧汇总一次。
void nvn_vk_pcprof_tick(void) {
    if (!pcprof_enabled()) return;
    const int me = (int)syscall(SYS_gettid);
    if (!g_pc_timer_live || g_pc_tid != me) {
        if (g_pc_timer_live) { timer_delete(g_pc_timer); g_pc_timer_live = 0; }
        struct sigaction sa;
        memset(&sa, 0, sizeof sa);
        sa.sa_sigaction = pcprof_sig;
        sa.sa_flags = SA_SIGINFO | SA_RESTART;
        sigemptyset(&sa.sa_mask);
        sigaction(SIGPROF, &sa, NULL);
        struct sigevent sev;
        memset(&sev, 0, sizeof sev);
        sev.sigev_notify = SIGEV_THREAD_ID;
        sev.sigev_signo = SIGPROF;
        sev.sigev_notify_thread_id = me;      // bionic：直接采这个线程
        if (timer_create(CLOCK_MONOTONIC, &sev, &g_pc_timer) != 0) {
            static int once;
            if (!once++) PCPROF_LOG("pcprof: timer_create failed (errno=%d); sampling off", errno);
            g_pc_timer_live = -1;             // 失败不再重试
            return;
        }
        struct itimerspec its;
        memset(&its, 0, sizeof its);
        its.it_interval.tv_nsec = 200000;     // 200 µs → 世界帧（~29 ms）约 145 个样本
        its.it_value = its.it_interval;
        timer_settime(g_pc_timer, 0, &its, NULL);
        g_pc_tid = me;
        g_pc_timer_live = 1;
        g_pc_n = 0;
        g_pc_drops = 0;
        PCPROF_LOG("pcprof: sampling tid=%d every 200 us", me);
        return;
    }
    if (g_pc_timer_live != 1) return;
    static unsigned frames;
    if (++frames % 256) return;
    unsigned n = g_pc_n;
    g_pc_n = 0;                              // 处理函数看到 0 会从头写；已汇总的样本已拷出
    if (n < 32) return;
    // 汇总必须是有界的、并且只在绘制线程上做很小的量：
    // 之前对每个样本调一次 dladdr（一万次/窗口，每次都要拿动态链接器锁扫 link map），
    // 真机上单这一跳就让绘制线程停掉几百毫秒（长帧 280–300 ms），是本模块自己造成的停顿。
    // 现在：先按原始 PC 做直方图（不调 dladdr），只对前 10 个 PC 及其主要调用点各解析一次。
    enum { HB = 13, HS = 1 << HB, TOPN = 10 };
    static unsigned long pcs[PCPROF_CAP];
    static unsigned pcnt[PCPROF_CAP];
    static int32_t ptab[HS];
    static unsigned long pkey[HS];
    static unsigned long lrpcs[TOPN][2];
    static unsigned lrcnt[TOPN][2];
    memset(ptab, 0, sizeof ptab);
    memset(lrcnt, 0, sizeof lrcnt);
    unsigned uniq = 0;
    for (unsigned i = 0; i < n; i++) {
        unsigned long pc = g_pc[i].pc;
        if (!pc) continue;
        unsigned long long mix = (unsigned long long)pc * 0x9e3779b97f4a7c15ull;
        unsigned h = (unsigned)((mix >> 33) ^ mix) & (HS - 1);
        int placed = 0;
        for (unsigned probe = 0; probe < 8; probe++, h = (h + 1) & (HS - 1)) {
            if (!ptab[h]) {
                if (uniq >= PCPROF_CAP) break;
                pcs[uniq] = pc; pcnt[uniq] = 1; ptab[h] = (int32_t)uniq + 1; pkey[h] = pc; uniq++;
                placed = 1; break;
            }
            if (pkey[h] == pc) { pcnt[ptab[h] - 1]++; placed = 1; break; }
        }
        (void)placed;
    }
    unsigned long top[TOPN]; unsigned topn[TOPN];
    for (int r = 0; r < TOPN; r++) {
        unsigned best = 0;
        for (unsigned k = 1; k < uniq; k++) if (pcnt[k] > pcnt[best]) best = k;
        if (uniq == 0 || pcnt[best] == 0) { topn[r] = 0; break; }
        top[r] = pcs[best]; topn[r] = pcnt[best];
        pcnt[best] = 0;
    }
    // 每个 top PC 的两个最常见调用点：一次遍历、TOPN 次比较，不再逐位重扫全表。
    for (unsigned i = 0; i < n; i++) {
        if (!g_pc[i].pc || !g_pc[i].lr) continue;
        for (int r = 0; r < TOPN && topn[r]; r++) {
            if (g_pc[i].pc != top[r]) continue;
            unsigned long lr = g_pc[i].lr;
            if (lrcnt[r][0] && lrpcs[r][0] == lr) { lrcnt[r][0]++; break; }
            if (!lrcnt[r][0]) { lrpcs[r][0] = lr; lrcnt[r][0] = 1; break; }
            if (!lrcnt[r][1] || lrpcs[r][1] == lr) { lrpcs[r][1] = lr; lrcnt[r][1]++; break; }
            if (lrcnt[r][0] <= lrcnt[r][1]) { lrpcs[r][0] = lr; lrcnt[r][0] = 1; } else { lrpcs[r][1] = lr; lrcnt[r][1] = 1; }
            break;
        }
    }
    PCPROF_LOG("pcprof: samples=%u uniq=%u drops=%u (dump every 256 frames)", n, uniq, g_pc_drops);
    unsigned long total = n ? n : 1;
    for (int r = 0; r < TOPN && topn[r]; r++) {
        Dl_info a, b; memset(&a, 0, sizeof a); memset(&b, 0, sizeof b);
        const char *dn = "?"; unsigned long off = top[r]; const char *sym = "?";
        if (dladdr((void *)(uintptr_t)top[r], &a)) {
            dn = a.dli_fname ? a.dli_fname : "?";
            off = top[r] - (unsigned long)(uintptr_t)a.dli_fbase;
            if (a.dli_sname) sym = a.dli_sname;
        }
        unsigned long l1o = 0, l2o = 0;
        const char *l1d = "-", *l2d = "-";
        if (lrcnt[r][0] && dladdr((void *)(uintptr_t)lrpcs[r][0], &b)) {
            l1d = b.dli_fname ? b.dli_fname : "?"; l1o = lrpcs[r][0] - (unsigned long)(uintptr_t)b.dli_fbase;
            if (b.dli_sname) l1d = b.dli_sname;
        }
        if (lrcnt[r][1] && dladdr((void *)(uintptr_t)lrpcs[r][1], &b)) {
            l2d = b.dli_fname ? b.dli_fname : "?"; l2o = lrpcs[r][1] - (unsigned long)(uintptr_t)b.dli_fbase;
            if (b.dli_sname) l2d = b.dli_sname;
        }
        PCPROF_LOG("  #%d pc=%s+0x%lx %s n=%u (%.1f%%) lr=[%s+0x%lx n=%u] [%s+0x%lx n=%u]",
                   r + 1, dn, off, sym, topn[r], 100.0 * (double)topn[r] / (double)total,
                   l1d, l1o, lrcnt[r][0], l2d, l2o, lrcnt[r][1]);
    }
}
