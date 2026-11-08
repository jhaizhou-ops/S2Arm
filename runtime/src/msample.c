// malloc 按调用点采样（诊断 S2A_MALLOC_SAMPLE=1，缺省关；10-24 总指挥：xc3 OOM 时低区 malloc 小块 392 MB 来源不明——宿主侧还是 Metal 内部）
//   挂 libmalloc 的 malloc_logger（MallocStackLogging 用的同一个钩子）：按分配字节每满 S2A_MALLOC_SAMPLE_KB（缺省 64 KB）抽一次，
//   记 8 层返回地址；抽中的地址进在用表，free / realloc 时减掉 → 每个调用点「估在用 = 抽中仍在用次数 × 间隔」。
//   钩子里不分配：固定表、os_unfair_lock、backtrace（Darwin 走 thread_stack_pcs，不 malloc）；全局原子计数（不用 __thread：首次取 TLS 会 malloc）。
//   收局 / 低区全列时 s2a_msample_note 打一行：符号在打印时才用 dladdr 解析
#include <dlfcn.h>
#include <execinfo.h>
#include <os/lock.h>
#include <pthread.h>
#include <unistd.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define LOG(...) do { fprintf(stderr, "[s2a] " __VA_ARGS__); fputc('\n', stderr); } while (0)
enum { MS_DEPTH = 8, MS_SITES = 4096, MS_LIVE = 1 << 17 };
enum { T_ALLOC = 2, T_DEALLOC = 4 };
typedef struct { uint64_t key; void *pc[MS_DEPTH]; int64_t live, n; uint64_t big; } ms_site;
typedef struct { uintptr_t a; int32_t site; int64_t w; } ms_slot;
static ms_site g_site[MS_SITES]; static int g_nsite;
static ms_slot g_live[MS_LIVE];   // 开放寻址；a = 0 空、a = 1 墓碑
static os_unfair_lock g_mu = OS_UNFAIR_LOCK_INIT;
static _Atomic uint64_t g_acc; static uint64_t g_step, g_drop_site, g_drop_live, g_nsamp;
static _Atomic int g_on;

static inline uint32_t hp(uintptr_t a) { a ^= a >> 33; a *= 0xff51afd7ed558ccdull; a ^= a >> 33; return (uint32_t)a & (MS_LIVE - 1); }
static void live_del(uintptr_t a) {   // 调用方持锁
    for (uint32_t i = hp(a), k = 0; k < MS_LIVE; i = (i + 1) & (MS_LIVE - 1), k++) {
        if (g_live[i].a == 0) return;
        if (g_live[i].a == a) { g_site[g_live[i].site].live -= g_live[i].w; g_live[i].a = 1; return; }
    }
}
static void sample(uintptr_t a, uint64_t sz, int64_t w) {   // w = 这次跨过的抽样间隔数 × 间隔（大块一次跨好几格）
    void *pc[MS_DEPTH + 2]; int n = backtrace(pc, MS_DEPTH + 2);
    uint64_t key = 1469598103934665603ull; for (int i = 2; i < n; i++) key = (key ^ (uintptr_t)pc[i]) * 1099511628211ull;
    os_unfair_lock_lock(&g_mu);
    int s = -1; for (int i = 0; i < g_nsite; i++) if (g_site[i].key == key) { s = i; break; }
    if (s < 0 && g_nsite < MS_SITES) { s = g_nsite++; g_site[s].key = key; for (int i = 0; i < MS_DEPTH; i++) g_site[s].pc[i] = i + 2 < n ? pc[i + 2] : NULL; }
    if (s < 0) { g_drop_site++; os_unfair_lock_unlock(&g_mu); return; }
    uint32_t i = hp(a), k = 0; for (; k < MS_LIVE && g_live[i].a > 1; i = (i + 1) & (MS_LIVE - 1), k++) ;
    if (k == MS_LIVE) g_drop_live++;
    else { g_live[i].a = a; g_live[i].site = s; g_live[i].w = w; g_site[s].live += w; }
    g_site[s].n++; if (sz >= (128u << 10)) g_site[s].big++; g_nsamp++;
    os_unfair_lock_unlock(&g_mu);
}
static void logger(uint32_t type, uintptr_t a1, uintptr_t a2, uintptr_t a3, uintptr_t res, uint32_t skip) {
    (void)a1; (void)skip;
    if (!atomic_load_explicit(&g_on, memory_order_relaxed)) return;
    uintptr_t freed = 0, got = 0; uint64_t sz = 0;
    if ((type & T_ALLOC) && (type & T_DEALLOC)) { freed = a2; sz = a3; got = res; }   // realloc：旧地址 a2、新大小 a3
    else if (type & T_DEALLOC) freed = a2;
    else if (type & T_ALLOC) { sz = a2; got = res; }
    if (freed && freed != got) { os_unfair_lock_lock(&g_mu); live_del(freed); os_unfair_lock_unlock(&g_mu); }
    if (!got || !sz) return;
    uint64_t before = atomic_fetch_add_explicit(&g_acc, sz, memory_order_relaxed);
    uint64_t cross = (before + sz) / g_step - before / g_step;
    if (cross) sample(got, sz, (int64_t)(cross * g_step));
}

__attribute__((visibility("default"), used)) void s2a_msample_note(const char *when);
static void *ms_tick(void *x) { (void)x; for (int m = 1;; m++) { sleep(60); char w[32]; snprintf(w, sizeof w, "第 %d 分钟", m); s2a_msample_note(w); } return NULL; }   // 每 60 秒一份（局被超时杀掉也留得下）
__attribute__((constructor(200))) static void ms_init(void) {
    const char *e = getenv("S2A_MALLOC_SAMPLE"); if (!e || *e != '1') return;
    const char *k = getenv("S2A_MALLOC_SAMPLE_KB"); g_step = (uint64_t)(k && atoi(k) > 0 ? atoi(k) : 64) << 10;
    void **ml = (void **)dlsym(RTLD_DEFAULT, "malloc_logger");
    if (!ml) { LOG("malloc 采样：【红】找不到 malloc_logger，不可用"); return; }
    *ml = (void *)logger; atomic_store(&g_on, 1);
    pthread_t t; pthread_create(&t, NULL, ms_tick, NULL); pthread_detach(t);
    LOG("malloc 采样已开：每 %llu KB 抽一次，记 %d 层调用栈（S2A_MALLOC_SAMPLE=1）", (unsigned long long)(g_step >> 10), MS_DEPTH);
}

// 一帧可读的名字：镜像短名!符号+偏移（无符号时 镜像+偏移）
static int pc_name(void *pc, char *o, size_t cap) {
    Dl_info d; if (!pc || !dladdr(pc, &d) || !d.dli_fname) return snprintf(o, cap, "%p", pc);
    const char *im = strrchr(d.dli_fname, '/'); im = im ? im + 1 : d.dli_fname;
    if (d.dli_sname) return snprintf(o, cap, "%s!%s+%#lx", im, d.dli_sname, (unsigned long)((uintptr_t)pc - (uintptr_t)d.dli_saddr));
    return snprintf(o, cap, "%s+%#lx", im, (unsigned long)((uintptr_t)pc - (uintptr_t)d.dli_fbase));
}
static int skip_frame(void *pc) {   // 分配器自身与 C++ / ObjC 包装层不算调用点
    Dl_info d; if (!pc || !dladdr(pc, &d) || !d.dli_fname) return 0;
    return strstr(d.dli_fname, "libsystem_malloc") || strstr(d.dli_fname, "libc++") || strstr(d.dli_fname, "libobjc");
}
__attribute__((visibility("default"), used)) void s2a_msample_note(const char *when) {
    if (!atomic_load(&g_on)) return;
    static ms_site snap[MS_SITES]; int ns; uint64_t nsamp, ds, dl;
    os_unfair_lock_lock(&g_mu); ns = g_nsite; memcpy(snap, g_site, (size_t)ns * sizeof *snap); nsamp = g_nsamp; ds = g_drop_site; dl = g_drop_live; os_unfair_lock_unlock(&g_mu);
    int64_t tot = 0; for (int i = 0; i < ns; i++) tot += snap[i].live;
    // 按调用镜像（第一层非分配器帧所在镜像）合计
    struct { const char *im; int64_t live; } byim[64]; int nim = 0;
    for (int i = 0; i < ns; i++) { if (snap[i].live <= 0) continue;
        void *pc = NULL; for (int f = 0; f < MS_DEPTH; f++) if (snap[i].pc[f] && !skip_frame(snap[i].pc[f])) { pc = snap[i].pc[f]; break; }
        Dl_info d; const char *im = pc && dladdr(pc, &d) && d.dli_fname ? d.dli_fname : "?"; const char *b = strrchr(im, '/'); im = b ? b + 1 : im;
        int j = 0; for (; j < nim; j++) if (!strcmp(byim[j].im, im)) break;
        if (j == nim && nim < 64) { byim[nim].im = im; byim[nim].live = 0; nim++; }
        if (j < nim) byim[j].live += snap[i].live; }
    char o[1600]; int k = snprintf(o, sizeof o, "malloc 采样 [%s]：每 %llu KB 抽一次，共抽 %llu 次，估在用 %.1f MB（调用点 %d 个，表满丢 %llu / %llu）；按调用镜像：", when,
                                   (unsigned long long)(g_step >> 10), (unsigned long long)nsamp, tot / 1048576.0, ns, (unsigned long long)ds, (unsigned long long)dl);
    for (int r = 0; r < 10 && k > 0 && (size_t)k < sizeof o; r++) { int b = -1; for (int j = 0; j < nim; j++) if (byim[j].live > 0 && (b < 0 || byim[j].live > byim[b].live)) b = j;
        if (b < 0) break; k += snprintf(o + k, sizeof o - k, " %s %.1f MB；", byim[b].im, byim[b].live / 1048576.0); byim[b].live = 0; }
    LOG("%s", o);
    for (int r = 0; r < 15; r++) { int b = -1; for (int i = 0; i < ns; i++) if (snap[i].live > 0 && (b < 0 || snap[i].live > snap[b].live)) b = i;
        if (b < 0) break;
        char l[900]; int m = snprintf(l, sizeof l, "malloc 采样 调用点 %d：估在用 %.1f MB（抽中 %lld 次，其中 ≥128 KB %llu 次）：", r + 1, snap[b].live / 1048576.0, (long long)snap[b].n, (unsigned long long)snap[b].big);
        int shown = 0; for (int f = 0; f < MS_DEPTH && shown < 4 && m > 0 && (size_t)m < sizeof l; f++) { if (!snap[b].pc[f] || (!shown && skip_frame(snap[b].pc[f]))) continue;
            if (shown) m += snprintf(l + m, sizeof l - m, " ← "); m += pc_name(snap[b].pc[f], l + m, sizeof l - m); shown++; }
        LOG("%s", l); snap[b].live = 0; }
}
