// CPU 采样器（诊断 S2A_CPUPROF=<开始秒>:<时长秒>，缺省关；10-29 帧率能耗线）：真机上看哪段代码吃 CPU，不依赖 Instruments 和 Mac 直连库。
//   起因：12 正式款里怪猎 / 塞尔达 / 八方 2 的提交线程每帧翻译 6.7–17 ms CPU（每次绘制 1.1–3.4 万周期），Mac 根都只出 iOS 直连库，热点没法在本机采。
//   做法：独立线程按 S2A_CPUPROF_HZ（缺省 1000）次 / 秒，挂起每条正在跑（TH_STATE_RUNNING）的线程，取 pc / lr、帧指针回溯 ≤ 16 层，立即放行。
//   挂起期间只写预分配的环形表：不分配、不拿锁、不符号化（被挂起的线程可能正持 malloc / dyld 锁）；窗口结束后统一放行再按函数解析
//   （宿主 dladdr → 函数起点；游戏模块按「模块+偏移」归到 256 字节块）。结果打进 host.log「[cpuprof]」行：每条线程的样本数、自身前 20、含子调用前 20。
//   S2A_CPUPROF_THREAD=<名字子串> 只采名字含它的线程（如 nx-89）。开销：每样本挂起 / 放行一次，约几微秒；只用于诊断局
#include "native.h"
#include <dlfcn.h>
#include <mach/mach.h>
#include <mach/thread_act.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define VA(x) ((x) & 0x0000007fffffffffull)   // 去掉返回地址高位的指针认证位
enum { CP_DEPTH = 16, CP_MAXS = 120000, CP_THR = 64, CP_TOP = 20 };
typedef struct { uint16_t thr; uint8_t n; uint64_t pc[CP_DEPTH]; } cp_sample;   // pc[0] = 当前 pc，之后是返回地址
static cp_sample *g_s; static int g_ns;
static struct { uint64_t tid; char name[64]; int n; } g_thr[CP_THR]; static int g_nthr;

static int rd(uint64_t a, uint64_t *v) {
    vm_size_t got = 0;
    return !(a & 7) && vm_read_overwrite(mach_task_self(), (vm_address_t)a, 8, (vm_address_t)v, &got) == KERN_SUCCESS && got == 8;
}
static int thr_slot(uint64_t tid, const char *name) {   // 采样线程自己调，不在挂起区间
    for (int i = 0; i < g_nthr; i++) if (g_thr[i].tid == tid) return i;
    if (g_nthr >= CP_THR) return CP_THR - 1;
    g_thr[g_nthr].tid = tid; snprintf(g_thr[g_nthr].name, sizeof g_thr[0].name, "%s", name && *name ? name : "无名"); return g_nthr++;
}
// 地址 → 函数键：宿主函数起点（dladdr），游戏模块按 256 字节块；名字写进 out
static uint64_t fkey(uint64_t a, char *out, size_t n) {
    module_t *m = module_of((void *)a);
    if (m) { uint64_t off = (a - (uint64_t)m->base) & ~0xffull; snprintf(out, n, "%s+%#llx", m->name, (unsigned long long)off); return (uint64_t)m->base + off; }
    Dl_info di;
    if (dladdr((void *)a, &di) && di.dli_sname) { snprintf(out, n, "%s", di.dli_sname); return (uint64_t)di.dli_saddr; }
    if (di.dli_fname) { const char *f = strrchr(di.dli_fname, '/'); snprintf(out, n, "?(%s)", f ? f + 1 : di.dli_fname); return (uint64_t)di.dli_fbase; }
    snprintf(out, n, "%#llx", (unsigned long long)a); return a;
}
typedef struct { uint64_t key; int self, incl; char name[96]; } cp_fn;
static int fn_cmp_self(const void *a, const void *b) { return ((const cp_fn *)b)->self - ((const cp_fn *)a)->self; }
static int fn_cmp_incl(const void *a, const void *b) { return ((const cp_fn *)b)->incl - ((const cp_fn *)a)->incl; }
static void report(double secs) {
    LOG("[cpuprof] 窗口 %.1f 秒，样本 %d（上限 %d）；按线程：", secs, g_ns, CP_MAXS);
    // 地址解析缓存：同一地址只 dladdr 一次
    enum { AC = 1 << 16 }; uint64_t *ak = calloc(AC, 8); int *av = calloc(AC, sizeof(int));
    cp_fn *fn = calloc(8192, sizeof *fn); int nfn = 0;
    if (!ak || !av || !fn) { LOG("[cpuprof] 内存不足，不出表"); free(ak); free(av); free(fn); return; }
    for (int t = 0; t < g_nthr; t++) {
        if (g_thr[t].n < 20) continue;
        nfn = 0; memset(ak, 0, AC * 8);
        for (int i = 0; i < g_ns; i++) {
            if (g_s[i].thr != t) continue;
            int seen[CP_DEPTH], ns = 0;
            for (int d = 0; d < g_s[i].n; d++) {
                uint64_t a = g_s[i].pc[d]; if (d) a -= 4;   // 返回地址退回调用指令
                uint32_t h = (uint32_t)((a * 0x9e3779b97f4a7c15ull) >> 48); int f = -1;
                for (uint32_t k = 0; k < AC; k++, h = (h + 1) & (AC - 1)) {
                    if (ak[h] == a) { f = av[h]; break; }
                    if (!ak[h]) { char nm[96]; uint64_t key = fkey(a, nm, sizeof nm); int j;
                        for (j = 0; j < nfn && fn[j].key != key; j++) {}
                        if (j == nfn && nfn < 8192) { fn[nfn].key = key; fn[nfn].self = fn[nfn].incl = 0; snprintf(fn[nfn].name, sizeof fn[0].name, "%s", nm); nfn++; }
                        f = j < nfn ? j : -1; ak[h] = a; av[h] = f; break; }
                }
                if (f < 0) continue;
                if (!d) fn[f].self++;
                int dup = 0; for (int q = 0; q < ns; q++) if (seen[q] == f) dup = 1;
                if (!dup) { fn[f].incl++; seen[ns++] = f; }
            }
        }
        int tot = g_thr[t].n;
        LOG("[cpuprof] 线程「%s」%d 样本（约 %.0f%% 一核）", g_thr[t].name, tot, secs > 0 ? 100.0 * tot / (secs * (getenv("S2A_CPUPROF_HZ") ? atof(getenv("S2A_CPUPROF_HZ")) : 1000.0)) : 0);
        qsort(fn, (size_t)nfn, sizeof *fn, fn_cmp_self);
        for (int j = 0; j < nfn && j < CP_TOP && fn[j].self; j++) LOG("[cpuprof]   自身 %5.1f%% %s", 100.0 * fn[j].self / tot, fn[j].name);
        qsort(fn, (size_t)nfn, sizeof *fn, fn_cmp_incl);
        for (int j = 0; j < nfn && j < CP_TOP; j++) LOG("[cpuprof]   含子 %5.1f%% %s", 100.0 * fn[j].incl / tot, fn[j].name);
    }
    free(ak); free(av); free(fn);
}
static void *cp_main(void *arg) {
    (void)arg; pthread_setname_np("s2a-cpuprof");
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    const char *e = getenv("S2A_CPUPROF"), *hz_e = getenv("S2A_CPUPROF_HZ"), *flt = getenv("S2A_CPUPROF_THREAD");
    double t0 = atof(e), dur = strchr(e, ':') ? atof(strchr(e, ':') + 1) : 20, hz = hz_e ? atof(hz_e) : 1000;
    if (dur <= 0) dur = 20;
    if (hz < 10) hz = 10;
    struct timespec ts = {(time_t)t0, (long)((t0 - (time_t)t0) * 1e9)}; nanosleep(&ts, NULL);
    LOG("[cpuprof] 开始采样：%.0f 秒、每秒 %.0f 次%s%s", dur, hz, flt ? "，只采名字含 " : "", flt ? flt : "");
    thread_t self = mach_thread_self(); struct timespec beg, now; clock_gettime(CLOCK_MONOTONIC, &beg);
    long per = (long)(1e9 / hz);
    for (;;) {
        clock_gettime(CLOCK_MONOTONIC, &now);
        double el = (double)(now.tv_sec - beg.tv_sec) + (now.tv_nsec - beg.tv_nsec) / 1e9;
        if (el >= dur || g_ns >= CP_MAXS) break;
        thread_act_array_t th; mach_msg_type_number_t n = 0;
        if (task_threads(mach_task_self(), &th, &n) == KERN_SUCCESS) {
            for (mach_msg_type_number_t i = 0; i < n && g_ns < CP_MAXS; i++) {
                if (th[i] == self) continue;
                thread_extended_info_data_t ei; mach_msg_type_number_t c = THREAD_EXTENDED_INFO_COUNT;
                if (thread_info(th[i], THREAD_EXTENDED_INFO, (thread_info_t)&ei, &c) != KERN_SUCCESS || ei.pth_run_state != TH_STATE_RUNNING) continue;
                if (flt && !strstr(ei.pth_name, flt)) continue;
                thread_identifier_info_data_t ii; c = THREAD_IDENTIFIER_INFO_COUNT;
                uint64_t tid = thread_info(th[i], THREAD_IDENTIFIER_INFO, (thread_info_t)&ii, &c) == KERN_SUCCESS ? ii.thread_id : 0;
                int slot = thr_slot(tid, ei.pth_name);
                cp_sample *s = &g_s[g_ns];
                if (thread_suspend(th[i]) != KERN_SUCCESS) continue;
                arm_thread_state64_t st; mach_msg_type_number_t sc = ARM_THREAD_STATE64_COUNT; int ok = 0;
                if (thread_get_state(th[i], ARM_THREAD_STATE64, (thread_state_t)&st, &sc) == KERN_SUCCESS) {
                    uint64_t fp = arm_thread_state64_get_fp(st); int d = 0;
                    s->pc[d++] = VA(arm_thread_state64_get_pc(st));
                    for (; d < CP_DEPTH && fp; ) { uint64_t nfp, ret; if (!rd(fp, &nfp) || !rd(fp + 8, &ret) || !VA(ret)) break; s->pc[d++] = VA(ret); if (nfp <= fp) break; fp = nfp; }
                    s->n = (uint8_t)d; s->thr = (uint16_t)slot; ok = 1;
                }
                thread_resume(th[i]);
                if (ok) { g_ns++; g_thr[slot].n++; }
            }
            for (mach_msg_type_number_t i = 0; i < n; i++) mach_port_deallocate(mach_task_self(), th[i]);
            vm_deallocate(mach_task_self(), (vm_address_t)th, n * sizeof *th);
        }
        struct timespec w = {0, per}; nanosleep(&w, NULL);
    }
    clock_gettime(CLOCK_MONOTONIC, &now);
    mach_port_deallocate(mach_task_self(), self);
    report((double)(now.tv_sec - beg.tv_sec) + (now.tv_nsec - beg.tv_nsec) / 1e9);
    return NULL;
}
// 环境变量在 envfile_boot（constructor 99）之后读：iOS 上 Documents/env.txt 设的也认
__attribute__((constructor(210))) static void cp_init(void) {
    const char *e = getenv("S2A_CPUPROF"); if (!e || !*e) return;
    if (!(g_s = calloc(CP_MAXS, sizeof *g_s))) { LOG("[cpuprof] 样本表分配失败，不采"); return; }
    pthread_t t; pthread_attr_t a; pthread_attr_init(&a); pthread_attr_setdetachstate(&a, PTHREAD_CREATE_DETACHED);
    if (pthread_create(&t, &a, cp_main, NULL)) LOG("[cpuprof] 起采样线程失败");
    pthread_attr_destroy(&a);
}
