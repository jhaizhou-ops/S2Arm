// 确定性探针单测：① 开关关（缺省）时打点函数的开销；② 开着时两条线程交替拿锁互斥、交接计数准确
#include "../src/native.h"
#include <pthread.h>
#include <signal.h>
#include <errno.h>
#include <stdatomic.h>
#include <time.h>
#include <string.h>
#include <unistd.h>
#include <mach-o/dyld.h>   // _NSGetExecutablePath（结构判据反汇编自身用）
// plat.h stub: det.c installs SIGUSR2 through the platform layer.
int plat_fault_install(int sig, void (*fn)(int, siginfo_t *, void *), unsigned flags) {
    struct sigaction sa; memset(&sa, 0, sizeof sa); sa.sa_sigaction = fn; sa.sa_flags = SA_SIGINFO;
    if (flags & 1u) sa.sa_flags |= SA_ONSTACK;
    if (flags & 2u) sa.sa_flags |= SA_RESTART;
    sigemptyset(&sa.sa_mask);
    return sigaction(sig, &sa, NULL) ? errno : 0;
}

uint64_t now_ns(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (uint64_t)t.tv_sec * 1000000000ull + (uint64_t)t.tv_nsec; }
void s2a_where(uint64_t a, char *b, size_t n) { snprintf(b, n, "%#llx", (unsigned long long)a); }
void s2a_det_apply_host(uint32_t id, int op) { (void)id; (void)op; }   // 桩：单测不链线程层
void s2a_thread_dump(void) {}
void s2a_backtrace(uint64_t fp) { (void)fp; }
int s2a_det_mem_regions(uint64_t *b, uint64_t *n, int max) { (void)b; (void)n; (void)max; return 0; }   // 桩：单测不链内存层
void s2a_det_tlr_region(uint64_t *b, uint64_t *n) { *b = 0; *n = 0; }
S2A_TEST_MOD_TABLE(64); int g_nmod;
extern int g_det; void s2a_det_acquire(void), s2a_det_release(void), s2a_det_yield(void), s2a_det_init(void);
static int fails; static void check(const char *w, int ok) { printf("%s %s\n", ok ? "✓" : "✗", w); fails += !ok; }

// 结构判据（替代原计时判据——计时判「关着时零成本」在 mini 高负载 / 能效核上永远不稳，903cf6b4、7f6ebf2f 两次调口径仍偶发红）：
// 反汇编三个打点函数，确认「开关关」路径（入口块：读全局开关 g_det + 第一个条件分支走掉；det.c 里加了屏障，g_det==0 不读 t_held）
// 没有逻辑调用（bl/blr）、没有系统调用（svc）、没有写内存。确定性，负载多高都不变。
// 编译器的栈帧管理不算「逻辑」：栈探测 ___chkstk_darwin（大栈帧时 blr）与栈保护 ___stack_chk（canary 写 [x29）、
// 以及 prologue 的 stp/str 到 [sp/[x29，都白名单放过——它们开销固定、不随负载。
static int det_offpath_clean(void) {
    char self[4096]; uint32_t n = sizeof self;
    if (_NSGetExecutablePath(self, &n)) { printf("  结构判据：取不到自身路径\n"); return 1; }
    const char *fns[] = { "s2a_det_release", "s2a_det_acquire", "s2a_det_yield" };
    int bad = 0;
    for (int i = 0; i < 3; i++) {
        char cmd[512];
        snprintf(cmd, sizeof cmd, "otool -tV '%s' 2>/dev/null | awk '/^_%s:/{on=1;next} on&&/^_[A-Za-z]/{exit} on{print}'", self, fns[i]);
        FILE *f = popen(cmd, "r"); if (!f) { printf("  %s：otool 起不来\n", fns[i]); bad++; continue; }
        char line[1024]; int viol = 0, seen = 0, done = 0, prev_stkrt = 0;
        while (fgets(line, sizeof line, f)) {
            if (done) continue; seen++;
            char *t1 = strchr(line, '\t'); char *m = t1 ? t1 + 1 : line;          // 跳过地址列到助记符
            char mn[16] = ""; { char *t2 = strchr(m, '\t'); size_t L = t2 ? (size_t)(t2 - m) : strcspn(m, "\n"); if (L >= sizeof mn) L = sizeof mn - 1; memcpy(mn, m, L); mn[L] = 0; }
            int stkrt_ldr = strstr(line, "___chkstk") || strstr(line, "___stack_chk");   // 这行读的是栈探测/栈保护符号
            if (!strncmp(mn, "cbz", 3) || !strncmp(mn, "cbnz", 4) || !strncmp(mn, "tbz", 3) || !strncmp(mn, "tbnz", 4) || !strncmp(mn, "b.", 2) || !strcmp(mn, "ret")) { done = 1; continue; }  // 第一个条件分支 / ret：关路径在此走掉，入口块结束
            if (!strcmp(mn, "bl") || !strcmp(mn, "blr")) {
                if (prev_stkrt) { prev_stkrt = 0; continue; }                     // ___chkstk_darwin 栈探测：编译器栈管理，放过
                printf("  %s 关路径入口块有逻辑调用 %s\n", fns[i], mn); viol = 1; done = 1; continue;
            }
            if (!strcmp(mn, "svc")) { printf("  %s 关路径有 svc（系统调用）\n", fns[i]); viol = 1; done = 1; continue; }
            if (!strncmp(mn, "st", 2)) {
                if (strstr(line, "[sp") || strstr(line, "[x29")) { prev_stkrt = stkrt_ldr; continue; }   // 栈帧 / canary 写，放过
                printf("  %s 关路径有非栈 store %s（写内存）\n", fns[i], mn); viol = 1; done = 1; continue;
            }
            prev_stkrt = stkrt_ldr;
        }
        pclose(f);
        if (!seen) { printf("  %s：反汇编取不到符号（被 strip？）\n", fns[i]); bad++; }
        else if (!viol) printf("  ✓ %s 关路径入口块干净（读开关 + 分支；栈帧/栈探测除外，无逻辑调用 / 系统调用 / 非栈写）\n", fns[i]);
        if (viol) bad++;
    }
    return bad;
}
static _Atomic int inside, overlap; static long iters = 200000;
static void *worker(void *a) { (void)a; for (long i = 0; i < iters; i++) { s2a_det_acquire(); if (atomic_fetch_add(&inside, 1)) atomic_store(&overlap, 1); atomic_fetch_sub(&inside, 1); s2a_det_release(); } return NULL; }
// 基线：三个互不相同、不内联、什么都不做的函数（编译器不能合并 / 删掉调用），代价 = 调用 + 返回
__attribute__((noinline)) static void nop_a(void) { __asm__ volatile(""); }
__attribute__((noinline)) static void nop_b(void) { __asm__ volatile(""); }
__attribute__((noinline)) static void nop_c(void) { __asm__ volatile(""); }
int main(void) {
    // ① 关：一次系统调用多出的是 release + acquire，一次读计数器多出的是 yield。要证明的是「关着时只是判一下标志就回」，
    //    所以和同样三次调用空函数（非内联、同样跨调用）比，不和绝对纳秒比：两组交替各 5 轮 × 200 万次、各取最小那轮——
    //    抢占只会让耗时变大；同一时段、同一种核上量的两组，核类型 / 主频 / 整机负载对两边一样
    //    （原先判绝对 < 20 ns：10-22 mini 门禁 20.09 ns 偶发红，能效核满载下三次跨文件调用本身就接近 20 ns）
    double per = 1e9, base = 1e9;
    for (int r = 0; r < 5; r++) {
        uint64_t t0 = now_ns(); for (int i = 0; i < 2000000; i++) { s2a_det_release(); s2a_det_acquire(); s2a_det_yield(); }
        double p = (now_ns() - t0) / 2e6; if (p < per) per = p;
        t0 = now_ns(); for (int i = 0; i < 2000000; i++) { nop_a(); nop_b(); nop_c(); }
        p = (now_ns() - t0) / 2e6; if (p < base) base = p;
    }
    printf("  关闭时每次（release + acquire + yield）%.2f ns，同样三次调用空函数 %.2f ns（各 5 轮取最小）\n", per, base);
    //    门槛按比值定：本机读数比值约 2.7（打点函数跨文件、有栈帧），整机同比变慢时比值不变；关闭路径若退化成拿锁 / 进内核是 10 倍以上
    printf("  （计时仅参考、不判红：开关关路径开销受机器负载 / 能效核影响，不作判据）\n");
    check("开关关闭时三个打点关路径只有读开关 + 分支、无逻辑调用 / 系统调用 / 非栈写（结构判据，反汇编确认，负载无关）", det_offpath_clean() == 0);
    // ② 开：两条线程各拿放 20 万次，从不同时在锁内
    setenv("S2A_DET", "1", 1); s2a_det_init();
    pthread_t a, b; pthread_create(&a, NULL, worker, NULL); pthread_create(&b, NULL, worker, NULL); pthread_join(a, NULL); pthread_join(b, NULL);
    check("开着时两条线程从不同时持锁（40 万次拿放）", !atomic_load(&overlap));
    { int t_det_hostwrite(const char *); char lp[] = "/tmp/t_det_rec_XXXXXX"; int fd = mkstemp(lp); if (fd >= 0) close(fd); fails += t_det_hostwrite(lp); unlink(lp); }
    printf("%s t_det：%d 处不符（共 5 项）\n", fails ? "✗" : "✓", fails); return fails != 0;
}
// ③ 宿主写游戏内存（记录档）：游戏线程持锁时宿主线程的写先入待办，放锁时才写进去，且进了日志（类型 6，地址 / 长度 / 数据对）
static char g_mem[64]; static _Atomic int wrote;
static void *host_writer(void *a) { (void)a; void s2a_det_host_write(uint64_t, const void *, uint64_t); s2a_det_host_write((uint64_t)g_mem, "主机写的字节ABC", 18); atomic_store(&wrote, 1); return NULL; }
int t_det_hostwrite(const char *logp) {
    int bad = 0; setenv("S2A_DET_REC", logp, 1); s2a_det_init();
    s2a_det_acquire();
    pthread_t h; pthread_create(&h, NULL, host_writer, NULL); while (!atomic_load(&wrote)) usleep(1000);
    int before = memcmp(g_mem, "主机写的字节ABC", 18) != 0;   // 持锁期间还没写进去
    s2a_det_release();
    int after = memcmp(g_mem, "主机写的字节ABC", 18) == 0;
    void s2a_det_summary(void); s2a_det_summary(); pthread_join(h, NULL);
    FILE *f = fopen(logp, "rb"); uint8_t buf[4096]; size_t n = f ? fread(buf, 1, sizeof buf, f) : 0; if (f) fclose(f);
    int found = 0; for (size_t i = 0; i + 16 <= n; i += 16) if (buf[i] == 6 && *(uint32_t *)(buf + i + 4) == 18 && *(uint64_t *)(buf + i + 8) == (uint64_t)g_mem && i + 48 <= n && !memcmp(buf + i + 16, "主机写的字节ABC", 16)) found = 1;
    printf("%s 持锁时宿主写先入待办（放锁前游戏内存未变）\n", before ? "✓" : "✗"); bad += !before;
    printf("%s 放锁时按序写进游戏内存\n", after ? "✓" : "✗"); bad += !after;
    printf("%s 日志里有这次宿主写（地址 / 长度 / 数据）\n", found ? "✓" : "✗"); bad += !found;
    return bad;
}
