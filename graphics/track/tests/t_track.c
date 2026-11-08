// 16 KB 页精确写跟踪（graphics/track/track.c）单测。期望值按「宿主页 16 KB = 4 个 4 KB 子页」与 Ryujinx MemoryTracking 语义手算，不读被测实现。
// 缺页走真 mprotect + 真信号（本测试装的信号处理 = 原生层约定：先调 s2a_track_fault，返回 1 重执行）。
// ①–④ 写跟踪（READ）4 KB 语义、⑤ 并发写观察中子页、⑥–⑫ GPU 改过子页（NONE）免回写精确写（迁自旧库 t_track 与性能线免读回补丁），
// ⑬ 一次排空交整批（不逐段回调）、⑭ 快照槽满逐次报红并退回、⑮ NONE 子页并发写、⑯ 信号量写后游戏写同一子页（对拍找到的漏报）、
// ⑱ 解除映射后不再回写：GPU 改过的子页上 CPU 写过（快照待比对），随后 Ryujinx 改成不跟踪（解除映射）→ 排空不得再报该子页（原版不跟踪即不发事件、不回写）；
// ⑲ 托管写（s2a_track_write）到 GPU 改过的子页：登记了回调就先回写（A 方案），CPU 没写的字节是 GPU 的、写的字节是 CPU 的；
// ㉑ READFLUSH 诊断开关（s2a_track_set_readflush）：GPU 改过的子页所在页不可读；游戏读同页任一子页 → 先回写整页的 GPU 改过子页（按读事件）、读到 GPU 的数据；
//    宿主读不可读页 → 放成只读、不回写（读到内存旧值）；开关关时游戏读到旧值（反证 = 缺省「免读回」语义）。
// ⑰ 同值写（A 方案）：GPU 改过的子页上 CPU 写入与内存旧值相同的字节——原版语义「先回写、再 CPU 写」，结果是 CPU 的字节；旧路径（排空合并）反证会盖成 GPU 的。
#include "../s2a_track.h"
#include <signal.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>
#include <pthread.h>
#include <stdatomic.h>
#include <time.h>
#include <errno.h>
#include <sys/ucontext.h>
#include <sys/wait.h>
#include <mach/mach.h>
#include "s2a_emul_ld.h"
#include "s2a_emul_st.h"

// ⑰ 用游戏代码那条路：s2a_track_fault_guest 回 2 时在这里直接调 s2a_track_touch（宿主里由 touch.c 改道到正常上下文调；本测试回调是纯 C，信号里调无妨）
static volatile sig_atomic_t g_guest;   // 信号处理里读：volatile，否则「置 1、写、置 0」的置 1 会被当死存储删掉
// ㉖ 缺页处模拟读（同原生层 crash.c 将接的那一步）：游戏读不可读页、碰的子页不是 GPU 改过的 → 从可读别名模拟这条读。g_alias / g_alias_of = 别名页与它对应的游戏页
static volatile uint64_t g_alias, g_alias_of;
// ㉛ 拦写模拟（同原生层 crash.c 将接的那一步）：游戏写到 GPU 改过的子页、写跟踪说能模拟 → 经可写别名 g_wal 替它写、记位图、pc 前进
static volatile uint64_t g_wal;
static void on_sig(int s, siginfo_t *si, void *uc) {
    int w = (int)(((ucontext_t *)uc)->uc_mcontext->__es.__esr >> 6 & 1);   // 数据中止的 WnR 位（同原生层 crash.c）
    uint64_t fa = (uint64_t)(uintptr_t)si->si_addr;
    if (g_guest && !w && g_alias && (fa & ~0x3FFFull) == g_alias_of && s2a_track_read_emulable(si->si_addr)
        && s2a_emul_load(uc, fa, (const uint8_t *)(uintptr_t)(g_alias + (fa & 0x3FFF)), s2a_track_emul_ok)) { s2a_track_note_emul(); return; }
    if (g_guest && w && g_wal && (fa & ~0x3FFFull) == g_alias_of && s2a_track_store_try(si->si_addr)) {
        uint64_t ea = 0, len = 0;
        if (s2a_emul_store(uc, fa, (uint8_t *)(uintptr_t)(g_wal + (fa & 0x3FFF)), s2a_track_store_ok, &ea, &len)) { s2a_track_store_done(ea, len, 0); return; } }
    if (g_guest) { int r = s2a_track_fault_guest(si->si_addr, w, 0); if (r == 2) { s2a_track_touch((uint64_t)(uintptr_t)si->si_addr); return; } if (r) return; _exit(4); }
    if (s2a_track_fault(si->si_addr, w)) return; _exit(4); }
// ⑰ 模拟 Ryujinx 收到 VirtualMemoryEvent：GPU 改过的子页先把 GPU 侧数据回写进内存（flush），再按读 / 写改保护
static uint8_t g_gpu[0x4000]; static uint64_t g_gb;
// 回写用托管写（同 Ryujinx 贴图回写经 GetWritableRegion → s2a_track_write）：回调里再写同页不得再触发回写（重入即无限递归）
static int g_touch_depth, g_touch_maxdepth; static volatile int g_touch_n, g_touch_w;   // 信号处理里改、主流程读：volatile（同 g_guest）
static void ryu_touch(uint64_t a, uint64_t n, int write) {
    g_touch_n++; g_touch_w += write;
    if (++g_touch_depth > g_touch_maxdepth) g_touch_maxdepth = g_touch_depth;
    if (g_touch_depth < 8) { s2a_track_write(a, n); memcpy((void *)a, g_gpu + (a - g_gb), n); }
    s2a_track_reprotect(a, n, write ? S2A_TRACK_RW : S2A_TRACK_READ); g_touch_depth--; }
// ㉗ 贴图句柄整段回写：请回写子页 a 时，Ryujinx 连带回写并改保护同页的 g_grp_also（同一贴图句柄覆盖两个子页）；g_grp_noop = 1 时什么都不回写、不改保护（它那边已无可回写）
static volatile uint64_t g_grp_also; static volatile int g_grp_noop;
static void ryu_touch_grp(uint64_t a, uint64_t n, int write) {
    g_touch_n++;
    if (g_grp_noop) return;
    s2a_track_write(a, n); memcpy((void *)a, g_gpu + (a - g_gb), n); s2a_track_reprotect(a, n, S2A_TRACK_READ);
    if (g_grp_also && g_grp_also != a) { uint64_t b = g_grp_also; s2a_track_write(b, n); memcpy((void *)b, g_gpu + (b - g_gb), n); s2a_track_reprotect(b, n, S2A_TRACK_READ); } }
// ㉙ 部分回写（同产品 TextureGroup 部分回写 + RegionHandle.S2AKeepAction）：只把被碰的子页从 GPU 侧不经跟踪写回、只放开这一个子页，其余子页的拦截不动
static void ryu_touch_part(uint64_t a, uint64_t n, int write) {
    __atomic_fetch_add(&g_touch_n, 1, __ATOMIC_RELAXED);   // 两条读线程的缺页并发进来：普通自增会丢计数（10-24 ㉙ 回写次数偶发 < 400）
    s2a_track_write_untracked(a, g_gpu + (a - g_gb), n, 1);
    s2a_track_reprotect(a, n, write ? S2A_TRACK_RW : S2A_TRACK_READ); }
static uint8_t *g_part_mem; static volatile int g_part_bad[2];
// ㉜ 回写只写精确修改区间 [g_mlo, g_mhi)（同产品 Buffer.FlushImpl 只写修改区间），再按读 / 写改保护
static volatile uint64_t g_mlo, g_mhi;
static void ryu_touch_exact(uint64_t a, uint64_t n, int write) {
    __atomic_fetch_add(&g_touch_n, 1, __ATOMIC_RELAXED); g_touch_w += write;   // ㉛⑧ 两条写线程会并发进来
    uint64_t x0 = a > g_mlo ? a : g_mlo, x1 = a + n < g_mhi ? a + n : g_mhi;
    if (x0 < x1) s2a_track_write_untracked(x0, g_gpu + (x0 - g_gb), x1 - x0, 1);
    s2a_track_reprotect(a, n, write ? S2A_TRACK_RW : S2A_TRACK_READ); }
// macOS 没有 pthread_barrier：三方屏障（主线程 + 两条读线程），按代数等
static pthread_mutex_t g_pb_mu = PTHREAD_MUTEX_INITIALIZER; static pthread_cond_t g_pb_cv = PTHREAD_COND_INITIALIZER; static int g_pb_n, g_pb_gen;
static void part_bar(void) { pthread_mutex_lock(&g_pb_mu); int gen = g_pb_gen; if (++g_pb_n == 3) { g_pb_n = 0; g_pb_gen++; pthread_cond_broadcast(&g_pb_cv); } else while (gen == g_pb_gen) pthread_cond_wait(&g_pb_cv, &g_pb_mu); pthread_mutex_unlock(&g_pb_mu); }
static void *part_reader(void *p) {
    int who = (int)(intptr_t)p; volatile uint8_t *v = g_part_mem;
    for (int r = 1; r <= 200; r++) { part_bar(); uint8_t x = v[who ? 0x3010 : 0x0010]; if (x != (uint8_t)r) g_part_bad[who]++; part_bar(); }
    return NULL; }
// ㉚ 缺页处理读记账值的竞态：钩子在两条分支之间把页改成可读（模拟别的线程 rf_apply / 改保护），看这次读能不能被接住
extern void (*s2a_track_test_hook2)(uintptr_t pn); void s2a_track_test_set_ro(uintptr_t pn);
static void hook_flip_ro(uintptr_t pn) { s2a_track_test_hook2 = NULL; s2a_track_test_set_ro(pn); }
// ㉒ 回写在另一条线程执行（双线程渲染：GPU 模拟线程持 RegionHandle 锁、等渲染线程执行回写）：回写的托管写走 g_xw
static void (*g_xw)(uint64_t, uint64_t);
static void *xflush(void *p) { uint64_t *an = p; g_xw(an[0], an[1]); memcpy((void *)(uintptr_t)an[0], g_gpu + (an[0] - g_gb), an[1]); return NULL; }
static void ryu_touch_x(uint64_t a, uint64_t n, int write) {
    g_touch_n++;
    if (++g_touch_depth > g_touch_maxdepth) g_touch_maxdepth = g_touch_depth;
    if (g_touch_depth < 4) { uint64_t an[2] = {a, n}; pthread_t t; pthread_create(&t, NULL, xflush, an); pthread_join(t, NULL); }
    s2a_track_reprotect(a, n, write ? S2A_TRACK_RW : S2A_TRACK_READ); g_touch_depth--; }
// ㉛⑧ 并发：两条线程各对同一被拦子页的不同 8 字节写 N 次（每次都缺页、模拟），主线程同时反复排空
static uint8_t *g_es_mem; static _Atomic int g_es_go, g_es_done;
static void *es_writer(void *p) {
    int who = (int)(intptr_t)p; volatile uint64_t *q = (volatile uint64_t *)(g_es_mem + (who ? 0x1C00 : 0x1400));
    while (!atomic_load(&g_es_go)) { }
    g_guest = 1; for (uint64_t k = 1; k <= 20000; k++) *q = k * 0x0101010101010101ull + (uint64_t)who; atomic_fetch_add(&g_es_done, 1); return NULL; }
// ㉞ 同局交替开关：覆盖写跟踪里的弱符号 s2a_alt_phase（原生层 alt.c 的同名函数），-1 没在交替 / 0 关段 / 1 开段
static volatile int g_test_alt = -1;
int s2a_alt_phase(void) { return g_test_alt; }
static int fail, count;
#define EXPECT(name, want, got) do { long long w_ = (long long)(want), g_ = (long long)(got); count++; \
    printf("%-56s 期望 %-14lld → 真结果 %-14lld %s\n", name, w_, g_, w_ == g_ ? "✓" : "✗"); fail += w_ != g_; } while (0)
static int prot_of(const void *p) {   // 页的当前保护（vm_region 读，不靠访问推断）
    vm_address_t a = (vm_address_t)p; vm_size_t sz = 0; vm_region_basic_info_data_64_t info; mach_msg_type_number_t c = VM_REGION_BASIC_INFO_COUNT_64; mach_port_t o = MACH_PORT_NULL;
    return vm_region_64(mach_task_self(), &a, &sz, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &c, &o) == KERN_SUCCESS ? info.protection : -1; }
void s2a_track_test_snap_chunks(int n);
static uint64_t faults(void) { s2a_track_stat s; s2a_track_stats(&s); return s.faults; }
static s2a_track_batch B;
static void drain(void) { s2a_track_drain(&B); }
// 测试里还给系统一段跟踪过的内存（㊶）：同产品 VM 替页——排空停稳 → s2a_track_backing_reset 清旧世代 → 解映射。只 munmap 时页记录（定向读时回写登记 rfm 等）
//   留在跟踪表里，后面用例的新 mmap 落回同一地址就带着它（10-30 ㊵ 偶发 READFLUSH 1）。登记过 READFLUSH 的用例一律这样释放
static void release_tracked(void *p, size_t n) { drain(); s2a_track_drain_done(); s2a_track_backing_reset((uint64_t)(uintptr_t)p, n); munmap(p, n); }
static int popc(const s2a_track_precise *r) { int n = 0; for (int i = 0; i < 64; i++) n += __builtin_popcountll(r->bits[i]); return n; }
static int bit(const s2a_track_precise *r, unsigned i) { return (int)(r->bits[i / 64] >> (i % 64) & 1); }
static const s2a_track_precise *rec_at(uint64_t a) { for (uint32_t i = 0; i < B.nprecise; i++) if (B.precise[i].addr == a) return &B.precise[i]; return NULL; }

// ⑤ / ⑮ 并发：写线程每轮先写子页 1（页只读时缺页、解开整页），再写子页 2 = 轮号（页已可写、不缺页，只能靠排空时比内容发现），
// 然后公布轮号、等主线程再排空两次。主线程模拟 Ryujinx：READ 级报到哪个子页就先 reprotect 再读（原版顺序）；NONE 级按位图读 CPU 写的字节。
// 期望：每次排空开始前已公布的轮号，在这次排空后都已被读到（漏报 = 内容已变却再也不报）
static uint8_t *g_rp; static _Atomic long g_seq, g_drains; static _Atomic int g_stop; static int g_perm;
static void *race_writer(void *a) {
    (void)a; volatile uint32_t *s1 = (volatile uint32_t *)(g_rp + 0x1000), *s2 = (volatile uint32_t *)(g_rp + 0x2000);
    for (long k = 1; !atomic_load(&g_stop); k++) {
        *s1 = (uint32_t)k; for (volatile int d = (int)(k * 7919 % 64); d > 0; d--) { } *s2 = (uint32_t)k;
        atomic_store(&g_seq, k); long d0 = atomic_load(&g_drains); while (atomic_load(&g_drains) < d0 + 2 && !atomic_load(&g_stop)) { }
    }
    return NULL;
}
static uint32_t g_known; static uint64_t g_rb;
static void race_apply(void) {
    for (uint32_t i = 0; i < B.nranges; i++) for (uint64_t s = B.ranges[i].addr; s < B.ranges[i].addr + B.ranges[i].size; s += 0x1000) if (s >= g_rb && s < g_rb + 0x4000) {
        s2a_track_reprotect(s, 0x1000, g_perm);
        if (s == g_rb + 0x2000) g_known = *(volatile uint32_t *)(g_rp + 0x2000);
    }
    for (uint32_t i = 0; i < B.nprecise; i++) if (B.precise[i].addr == g_rb + 0x2000) {   // 精确写：只取位图里的字节（GPU 侧的「已知内容」按字节更新）
        uint8_t *kn = (uint8_t *)&g_known; for (unsigned j = 0; j < 4; j++) if (bit(&B.precise[i], j)) kn[j] = g_rp[0x2000 + j];
    }
}
static long race_run(double secs, int perm, long *rounds) {
    g_rp = mmap(NULL, 0x4000, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); memset(g_rp, 0, 0x4000); g_rb = (uint64_t)(uintptr_t)g_rp; g_perm = perm;
    s2a_track_reprotect(g_rb, 0x4000, perm); g_known = 0; atomic_store(&g_seq, 0); atomic_store(&g_drains, 0); atomic_store(&g_stop, 0);
    pthread_t t; pthread_create(&t, NULL, race_writer, NULL);
    long lost = 0; struct timespec t0, t1; clock_gettime(CLOCK_MONOTONIC, &t0);
    for (;;) {
        long k = atomic_load(&g_seq);
        drain(); race_apply();
        if ((long)g_known < k) { lost++; g_known = (uint32_t)k; s2a_track_reprotect(g_rb + 0x2000, 0x1000, perm); }   // 记一次漏报，按「已知」补齐，继续测
        atomic_fetch_add(&g_drains, 1);
        clock_gettime(CLOCK_MONOTONIC, &t1); if ((t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) * 1e-9 > secs) break;
    }
    atomic_store(&g_stop, 1); pthread_join(t, NULL); *rounds = atomic_load(&g_seq);
    s2a_track_reprotect(g_rb, 0x4000, S2A_TRACK_RW); drain();
    return lost;
}

static int t30(void) {
    // 期望（按「读缺页时页正被别的线程改成可读，这次读必须重执行成功」直接定）：读到内存值 0x42、进程不退出。旧逻辑（两次读记账值）在这里返回 0 → 退出 4
    uint8_t *r = mmap(NULL, 0x4000, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); memset(r, 0x42, 0x4000); uint64_t ra = (uint64_t)(uintptr_t)r;
    s2a_track_set_readflush(0); s2a_track_prot_changed(ra, 0x4000); drain();
    s2a_track_reprotect(ra + 0x1000, 0x1000, S2A_TRACK_NONE); s2a_track_mark_readflush(ra, 0x4000);
    EXPECT("㉚ 前提：页不可读", VM_PROT_NONE, prot_of(r));
    s2a_track_test_hook2 = hook_flip_ro;
    volatile uint8_t *v = r; uint8_t x = v[0x2010];
    EXPECT("㉚ 竞态下读不可读页：重执行读到 0x42", 0x42, x);
    s2a_track_reprotect(ra, 0x4000, S2A_TRACK_RW); drain(); release_tracked(r, 0x4000);
    return 0; }
// ㊳ 读回环（READFLUSH 宿主读放成只读的页，下次排空设回不可读）溢出窗口（审计 #846 F-rfq-over-wait）。期望按「排空不能等一个永远不来的槽」直接定：
//   环里已有 4096 项（满）时第 4097 次宿主读的写入方在入环前停住，排空线程这时开始排空——排空必须在 3 秒内返回；
//   写入方随后入环，下一次排空把这页也设回不可读。另：不并发时 4097 次读一次排空，4097 页全部设回不可读（溢出走整表扫）
#define T38_N 4097
static _Atomic int g38_drain_go, g38_drain_done;
static void hook_rfq_hold(uintptr_t pn) { (void)pn; extern void (*s2a_track_test_rfq_put)(uintptr_t); s2a_track_test_rfq_put = NULL;
    atomic_store(&g38_drain_go, 1); usleep(300000); }   // 放排空线程进去，等它取完头指针、开始排空再继续
static void *t38_reader(void *a) { volatile uint8_t *v = a; (void)v[0x2010]; return NULL; }
static void *t38_drainer(void *a) { (void)a; while (!atomic_load(&g38_drain_go)) usleep(1000); s2a_track_batch bb; s2a_track_drain(&bb); s2a_track_drain_done(); atomic_store(&g38_drain_done, 1); return NULL; }
static void t38(void) {
    extern void (*s2a_track_test_rfq_put)(uintptr_t);
    uint8_t *r = mmap(NULL, (size_t)T38_N * 0x4000, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); uint64_t ra = (uint64_t)(uintptr_t)r;
    for (int round = 0; round < 2; round++) {
        s2a_track_set_readflush(0); s2a_track_prot_changed(ra, (uint64_t)T38_N * 0x4000); drain(); s2a_track_drain_done();
        for (int i = 0; i < T38_N; i++) { s2a_track_reprotect(ra + (uint64_t)i * 0x4000 + 0x1000, 0x1000, S2A_TRACK_NONE); s2a_track_mark_readflush(ra + (uint64_t)i * 0x4000, 0x4000); }
        volatile uint8_t *v = r;
        for (int i = 0; i < T38_N - 1; i++) (void)v[(size_t)i * 0x4000 + 0x2010];   // 环里 4096 项（满）
        if (round == 0) {
            (void)v[(size_t)(T38_N - 1) * 0x4000 + 0x2010]; drain(); s2a_track_drain_done();
            int none = 0; for (int i = 0; i < T38_N; i++) none += prot_of(r + (size_t)i * 0x4000) == VM_PROT_NONE;
            EXPECT("㊳ 不并发：4097 次宿主读、一次排空后设回不可读的页数", T38_N, none);
            continue;
        }
        atomic_store(&g38_drain_go, 0); atomic_store(&g38_drain_done, 0); s2a_track_test_rfq_put = hook_rfq_hold;
        pthread_t rd, dr; pthread_create(&dr, NULL, t38_drainer, NULL); pthread_create(&rd, NULL, t38_reader, r + (size_t)(T38_N - 1) * 0x4000);
        int ms = 0; while (!atomic_load(&g38_drain_done) && ms < 3000) { usleep(10000); ms += 10; }
        EXPECT("㊳ 写入方入环前被抢占时，排空 3 秒内返回", 1, atomic_load(&g38_drain_done));
        if (!atomic_load(&g38_drain_done)) { printf("%s：%d 项，失败 %d（㊳ 排空死等，持锁不放，后续用例跑不了）\n", "t_track", count, fail); _exit(1); }
        pthread_join(rd, NULL); pthread_join(dr, NULL);
        drain(); s2a_track_drain_done();
        EXPECT("㊳ 被抢占的那页：下一次排空设回不可读", VM_PROT_NONE, prot_of(r + (size_t)(T38_N - 1) * 0x4000));
    }
    s2a_track_reprotect(ra, (uint64_t)T38_N * 0x4000, S2A_TRACK_RW); drain(); s2a_track_drain_done(); release_tracked(r, (size_t)T38_N * 0x4000);
}
// ㊴ 苹果上 mprotect 失败不发布（审计 #836 F-apple-mp-lastp）：vm_protect 把页的最大保护压成只读，升可写的 mprotect 必失败。期望按「记账只认内核真落地的保护」定：
//   ① Ryujinx 改不跟踪（reprotect RW）升可写失败 → 页状态仍是只读、记账保护仍是只读（不发布可写）；
//   ② 游戏写这页（缺页里升可写失败）→ 不能当成功重执行（原来状态已发布可写，缺页自愈再失败、重执行，空转不退出），交回信号处理（本测试退出 4）。子进程里跑，2 秒内退出 4
int s2a_track_test_page(uintptr_t pn, int *lastp);
static void t39(void) {
    uint8_t *r = mmap(NULL, 0x4000, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); memset(r, 0x5a, 0x4000); uint64_t ra = (uint64_t)(uintptr_t)r; uintptr_t pn = (uintptr_t)ra >> 14;
    s2a_track_reprotect(ra, 0x4000, S2A_TRACK_READ); drain(); s2a_track_drain_done();
    int lp = -1, st = s2a_track_test_page(pn, &lp);
    EXPECT("㊴ 前提：页已只读（状态 1、记账保护 READ）", 1 * 16 + PROT_READ, st * 16 + lp);
    EXPECT("㊴ 前提：最大保护压成只读", KERN_SUCCESS, vm_protect(mach_task_self(), (vm_address_t)ra, 0x4000, TRUE, VM_PROT_READ));
    s2a_track_reprotect(ra, 0x4000, S2A_TRACK_RW);
    st = s2a_track_test_page(pn, &lp);
    EXPECT("㊴① 改不跟踪升可写失败：页状态仍只读（1）", 1, st);
    EXPECT("㊴① 记账保护仍是 READ（内核真值）", PROT_READ, lp);
    EXPECT("㊴① 内核保护确实没变", VM_PROT_READ, prot_of(r));
    s2a_track_reprotect(ra, 0x4000, S2A_TRACK_READ); drain(); s2a_track_drain_done();
    pid_t c = fork();
    if (c == 0) { alarm(2); r[0x100] = 1; _exit(0); }   // 写成功 = 0；交回信号处理 = 4；空转 = 被 alarm 杀（SIGALRM）
    int ws = 0; waitpid(c, &ws, 0);
    EXPECT("㊴② 游戏写、缺页里升可写失败：交回信号处理（退出 4，不空转）", 4, WIFEXITED(ws) ? WEXITSTATUS(ws) : 100 + (WIFSIGNALED(ws) ? WTERMSIG(ws) : 0));
}
// ㊵ 诊断查询 s2a_track_page_info（双人成行图形着色器取码读到旧字节的定因要它）：期望按设的状态直接写——
//   没跟踪过 → UINT64_MAX；整页设只读 → 状态 1、记账保护 READ、要保护 0xF；子页 1 标 GPU 改过并登记定向读时回写 → GPU 改过 0x2、READFLUSH 1、记账保护 NONE
static void t40(void) {
    uint8_t *r = mmap(NULL, 0x4000, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); memset(r, 0x33, 0x4000); uint64_t ra = (uint64_t)(uintptr_t)r;
    EXPECT("㊵ 从没跟踪过的地址（0x1000，没有叶子）：UINT64_MAX", (long long)-1, (long long)s2a_track_page_info(0x1000));   // 新 mmap 的地址可能复用前面用例跟踪过的页，叶子还在
    s2a_track_set_readflush(0); s2a_track_reprotect(ra, 0x4000, S2A_TRACK_READ); drain(); s2a_track_drain_done();
    uint64_t v = s2a_track_page_info(ra);
    EXPECT("㊵ 整页只读：状态", 1, v & 0xff); EXPECT("㊵ 整页只读：记账保护 READ", PROT_READ, v >> 8 & 0xff); EXPECT("㊵ 整页只读：要保护 0xF", 0xF, v >> 24 & 0xff);
    EXPECT("㊵ 整页只读：READFLUSH 没登记", 0, v >> 32 & 0xff);
    s2a_track_reprotect(ra + 0x1000, 0x1000, S2A_TRACK_NONE); s2a_track_mark_readflush(ra, 0x4000);
    v = s2a_track_page_info(ra + 0x2345);   // 页内任意地址同一页
    EXPECT("㊵ 子页 1 GPU 改过：GPU 改过位 0x2", 0x2, v >> 16 & 0xff); EXPECT("㊵ 登记定向读时回写：READFLUSH 1", 1, v >> 32 & 0xff);
    EXPECT("㊵ 有 GPU 改过子页的 READFLUSH 页：记账保护 NONE", PROT_NONE, v >> 8 & 0xff);
    s2a_track_reprotect(ra, 0x4000, S2A_TRACK_RW); drain(); s2a_track_drain_done(); release_tracked(r, 0x4000);
}
// ㊶ 释放过的地址被新映射复用（10-30 列车守望 ㊵「整页只读：READFLUSH 没登记」偶发 1 的定因）：定向读时回写登记（rfm）记在页记录上，只有
//   s2a_track_backing_reset（旧世代清除）才清；㉕ / ㊳ / ㊵ 登记过的页以前直接 munmap，新 mmap 落回同一地址就带着上一用例的登记。不靠分配器碰巧：
//   同一地址登记 → 按测试释放约定（release_tracked）释放 → MAP_FIXED 原址重映射 → READFLUSH 位期望 0（新世代没有登记）
static void t41(void) {
    uint8_t *r = mmap(NULL, 0x4000, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); uint64_t ra = (uint64_t)(uintptr_t)r;
    s2a_track_set_readflush(0); s2a_track_reprotect(ra, 0x4000, S2A_TRACK_READ); drain(); s2a_track_drain_done();
    s2a_track_mark_readflush(ra, 0x4000);
    EXPECT("㊶ 前提：登记后 READFLUSH 1", 1, s2a_track_page_info(ra) >> 32 & 0xff);
    s2a_track_reprotect(ra, 0x4000, S2A_TRACK_RW); release_tracked(r, 0x4000);
    uint8_t *q = mmap(r, 0x4000, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE | MAP_FIXED, -1, 0);
    EXPECT("㊶ 前提：原址重映射成功", (long long)ra, (long long)(uintptr_t)q);
    s2a_track_reprotect(ra, 0x4000, S2A_TRACK_READ); drain(); s2a_track_drain_done();
    EXPECT("㊶ 原址复用的新映射：READFLUSH 没登记（上一世代的登记已清）", 0, s2a_track_page_info(ra) >> 32 & 0xff);
    s2a_track_reprotect(ra, 0x4000, S2A_TRACK_RW); release_tracked(q, 0x4000);
}
// ㊱ 写前外挂通知的计数钩子（10-24 双轨）
static int g_wp_n; static uint64_t g_wp_a[4], g_wp_s[4];
static void wp_hook(uint64_t a, uint64_t n) { if (g_wp_n < 4) { g_wp_a[g_wp_n] = a; g_wp_s[g_wp_n] = n; } g_wp_n++; }
static void t36(void) {
    uint8_t *q = mmap(NULL, 0x4000, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); uint64_t qb = (uint64_t)(uintptr_t)q;
    static uint8_t src[0x20];
    s2a_track_set_write_prep(wp_hook); g_wp_n = 0;
    s2a_track_write(qb + 0x10, 0x8); s2a_track_write_quiet(qb + 0x100, 0x20); s2a_track_write_untracked(qb + 0x200, src, 0x20, 0);
    EXPECT("㊱ 写前通知：三个写入口各调一次钩子", 3, g_wp_n);
    EXPECT("㊱ write 的地址长度原样（起点）", qb + 0x10, g_wp_a[0]);
    EXPECT("㊱ write 的地址长度原样（长度）", 0x8, g_wp_s[0]);
    EXPECT("㊱ write_quiet 原样（起点）", qb + 0x100, g_wp_a[1]);
    EXPECT("㊱ write_untracked 原样（长度）", 0x20, g_wp_s[2]);
    s2a_track_set_write_prep(NULL); g_wp_n = 0;
    s2a_track_write(qb + 0x10, 0x8); s2a_track_write_quiet(qb + 0x100, 0x20); s2a_track_write_untracked(qb + 0x200, src, 0x20, 0);
    EXPECT("㊱ 登记 NULL 后三个入口都不调", 0, g_wp_n);
    munmap(q, 0x4000);
}
// ㊲ 换页事务与排空期互斥（原生层 svc_mem 改表系统调用：先改保护 / 换页、后重算记账；审计 #806 第 5 条续）。期望按协议手写：
//   排空期（drain → drain_done）在途时 begin 等到 drain_done 之后才返回；事务进行中新的 drain 等到 end 之后才返回；
//   end 提交 → 下次排空把这页跟踪中的子页按脏报（同 prot_changed）；不提交 → 不报、只放闸
static _Atomic int g37_in, g37_done, g37_ret;
static void *t37_drainer(void *a) { (void)a; s2a_track_batch bb; s2a_track_drain(&bb); atomic_store(&g37_in, 1); usleep(150000); atomic_store(&g37_done, 1); s2a_track_drain_done(); return NULL; }
static void *t37_late(void *a) { (void)a; s2a_track_batch bb; s2a_track_drain(&bb); atomic_store(&g37_ret, 1); s2a_track_drain_done(); return NULL; }
static void t37(void) {
    uint8_t *r = mmap(NULL, 0x4000, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); uint64_t ra = (uint64_t)(uintptr_t)r; memset(r, 0x37, 0x4000);
    s2a_track_reprotect(ra, 0x4000, S2A_TRACK_RW); drain(); s2a_track_drain_done();
    pthread_t t; pthread_create(&t, NULL, t37_drainer, NULL); while (!atomic_load(&g37_in)) { }
    int e = s2a_track_backing_begin(ra, 0x4000, 0); int after = atomic_load(&g37_done);
    EXPECT("㊲ 排空期在途：begin 等到 drain_done 之后才返回", 1, !e && after);
    pthread_join(t, NULL);
    pthread_create(&t, NULL, t37_late, NULL); usleep(150000);
    EXPECT("㊲ 换页事务进行中：新的 drain 还没返回（等 end）", 0, atomic_load(&g37_ret));
    s2a_track_backing_end(ra, 0x4000, 1, 0); pthread_join(t, NULL);
    EXPECT("㊲ end 之后：等着的 drain 返回", 1, atomic_load(&g37_ret));
    // 不提交：跟踪中的页不报；提交：按脏报整页（4 个跟踪中的子页连成一段）
    s2a_track_reprotect(ra, 0x4000, S2A_TRACK_READ); drain(); s2a_track_drain_done();
    s2a_track_backing_begin(ra, 0x4000, 0); s2a_track_backing_end(ra, 0x4000, 1, 0); drain(); s2a_track_drain_done();
    EXPECT("㊲ 事务没提交：不报脏", 0, B.nranges);
    EXPECT("㊲ 事务没提交：页仍只读（跟踪保护原样）", PROT_READ, prot_of(r));
    s2a_track_backing_begin(ra, 0x4000, 0); mprotect(r, 0x4000, PROT_NONE); mprotect(r, 0x4000, PROT_READ | PROT_WRITE); s2a_track_backing_end(ra, 0x4000, 1, 1); drain(); s2a_track_drain_done();
    EXPECT("㊲ 事务提交：报脏 1 段", 1, B.nranges);
    EXPECT("㊲ 事务提交：段 = 整页", 0x4000, B.nranges == 1 && B.ranges[0].addr == ra ? B.ranges[0].size : 0);
    EXPECT("㊲ 范围不是整宿主页：begin 回 EINVAL、不挂闸", EINVAL, s2a_track_backing_begin(ra + 0x1000, 0x1000, 0));
    s2a_track_reprotect(ra, 0x4000, S2A_TRACK_RW); drain(); s2a_track_drain_done(); munmap(r, 0x4000);
}
// 退休不能吞掉真实排空期或换页事务。这里没有客体线程，只有本线程消费完 batch 后才结束排空期。
static void t_session_retirement(void) {
    uint8_t *p = mmap(NULL, 0x4000, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (p == MAP_FAILED) { EXPECT("㊳ 实际跟踪页分配", 0, errno); return; }
    uint64_t a = (uint64_t)(uintptr_t)p;
    memset(p, 0x38, 0x4000);
    s2a_track_reprotect(a, 0x4000, S2A_TRACK_READ);
    p[0x1000] = 0x39;
    s2a_track_batch batch; s2a_track_drain(&batch);
    EXPECT("㊳ 排空期未消费完：退休拒绝", EBUSY, s2a_track_reset_session());
    EXPECT("㊳ 拒绝退休后 batch 仍有效：实际写过的子页", a + 0x1000, batch.nranges == 1 ? batch.ranges[0].addr : 0);
    EXPECT("㊳ 拒绝退休后 batch 仍有效：子页大小", 0x1000, batch.nranges == 1 ? batch.ranges[0].size : 0);
    s2a_track_drain_done();
    EXPECT("㊳ 开始实际换页事务", 0, s2a_track_backing_begin(a, 0x4000, 0));
    EXPECT("㊳ 换页事务未结束：退休拒绝", EBUSY, s2a_track_reset_session());
    s2a_track_backing_end(a, 0x4000, 1, 0);
    EXPECT("㊳ 排空消费和换页事务结束：退休成功", 0, s2a_track_reset_session());
    s2a_track_reprotect(a, 0x4000, S2A_TRACK_READ);
    p[0x2000] = 0x3a;
    s2a_track_drain(&batch);
    EXPECT("㊳ 退休后重新跟踪：只报告新一代写过的子页", a + 0x2000, batch.nranges == 1 ? batch.ranges[0].addr : 0);
    s2a_track_drain_done();
    EXPECT("㊳ 新一代消费结束后可再次退休", 0, s2a_track_reset_session());
    munmap(p, 0x4000);
}
#if defined(RING) && RING == 64
// #923: expected pages come from our mappings/protections, never from drain output.
static int covers(uint64_t a, uint64_t n) {
    for (uint32_t i = 0; i < B.nranges; i++)
        if (B.ranges[i].addr <= a && B.ranges[i].size >= n && a - B.ranges[i].addr <= B.ranges[i].size - n) return 1;
    return 0;
}
extern void (*s2a_track_test_ring_reserved)(uintptr_t);
extern void (*s2a_track_test_ring_loaded)(void);
extern void (*s2a_track_test_ring_published)(void);
static _Atomic int qr_reserved, qr_loaded, qr_published;
static uintptr_t qr_pn;
static void qr_reserve(uintptr_t pn) {
    if (pn != qr_pn) return;
    atomic_store(&qr_reserved, 1);
    while (!atomic_load(&qr_loaded)) {}
}
static void qr_load(void) {
    atomic_store(&qr_loaded, 1);
    while (!atomic_load(&qr_published)) {}
}
static void qr_publish(void) { atomic_store(&qr_published, 1); }
static void *qr_writer(void *p) { *(volatile uint8_t *)p = 0x44; return NULL; }
static void t_overflow_publish(void) {
    const size_t bytes = (RING + 14) * 0x4000;
    uint8_t *p = mmap(NULL, bytes, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    EXPECT("publication fixture mmap", 1, p != MAP_FAILED); if (p == MAP_FAILED) return;
    memset(p, 0x11, bytes);
    for (unsigned i = 0; i < RING + 9; i++) {
        uint8_t *a = p + i * 0x4000;
        s2a_track_reprotect((uint64_t)a, 0x1000, S2A_TRACK_READ); *(volatile uint8_t *)a = 0x22;
    }
    drain(); EXPECT("publication setup overflow", 1, B.overflow); s2a_track_drain_done();
    uint8_t *a = p + (RING + 10) * 0x4000;
    s2a_track_reprotect((uint64_t)a, 0x1000, S2A_TRACK_READ);
    qr_pn = (uintptr_t)a >> 14; atomic_store(&qr_reserved, 0); atomic_store(&qr_loaded, 0); atomic_store(&qr_published, 0);
    s2a_track_test_ring_reserved = qr_reserve; s2a_track_test_ring_loaded = qr_load; s2a_track_test_ring_published = qr_publish;
    pthread_t writer; pthread_create(&writer, NULL, qr_writer, a);
    while (!atomic_load(&qr_reserved)) {}
    // Producer stops after reserving a ticket. Consumer observes the slot first,
    // then releases it: no time/scheduler assumptions and no copied ring model.
    drain(); pthread_join(writer, NULL);
    s2a_track_test_ring_reserved = NULL; s2a_track_test_ring_loaded = NULL; s2a_track_test_ring_published = NULL;
    EXPECT("unpublished ticket cannot consume stale old page", 1, covers((uint64_t)a, 0x1000));
    s2a_track_drain_done();
    s2a_track_reprotect((uint64_t)a, 0x1000, S2A_TRACK_READ); *(volatile uint8_t *)a = 0x55;
    drain(); EXPECT("ticket page can enqueue after consumption", 1, covers((uint64_t)a, 0x1000)); s2a_track_drain_done();
    EXPECT("publication fixture retires tracker", 0, s2a_track_reset_session()); munmap(p, bytes);
}

extern void (*s2a_track_test_ring_reset_wait)(void);
extern void (*s2a_track_test_ring_retired)(unsigned);
extern void (*s2a_track_test_overflow_visited)(uintptr_t);
static unsigned qr_waited, qr_retired_writers;
static void qr_reset_wait(void) { qr_waited = 1; atomic_store(&qr_loaded, 1); }
static void qr_retired(unsigned writers) { qr_retired_writers = writers; }
static void qr_visited(uintptr_t pn) {
    if (pn == qr_pn) {
        s2a_track_test_overflow_visited = NULL;
        s2a_track_reprotect((uint64_t)(pn << 14), 0x1000, S2A_TRACK_READ);
        *(volatile uint8_t *)(pn << 14) = 0x66;
    }
}
static void t_overflow_recovery_writers(void) {
    const size_t bytes = (RING + 2) * 0x4000;
    uint8_t *p = mmap(NULL, bytes, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    EXPECT("recovery writer fixture mmap", 1, p != MAP_FAILED); if (p == MAP_FAILED) return;
    memset(p, 0x11, bytes);
    s2a_track_reprotect((uint64_t)p, 0x1000, S2A_TRACK_READ);
    qr_pn = (uintptr_t)p >> 14; atomic_store(&qr_reserved, 0); atomic_store(&qr_loaded, 0); atomic_store(&qr_published, 0);
    qr_waited = 0; qr_retired_writers = 99;
    s2a_track_test_ring_reserved = qr_reserve; s2a_track_test_ring_published = qr_publish;
    pthread_t writer; pthread_create(&writer, NULL, qr_writer, p); while (!atomic_load(&qr_reserved)) {}
    for (unsigned i = 1; i <= RING; i++) {
        uint8_t *a = p + i * 0x4000;
        s2a_track_reprotect((uint64_t)a, 0x1000, S2A_TRACK_READ); *(volatile uint8_t *)a = 0x22;
    }
    s2a_track_test_ring_reset_wait = qr_reset_wait; s2a_track_test_ring_retired = qr_retired;
    drain(); pthread_join(writer, NULL);
    s2a_track_test_ring_reserved = NULL; s2a_track_test_ring_published = NULL;
    s2a_track_test_ring_reset_wait = NULL; s2a_track_test_ring_retired = NULL;
    EXPECT("recovery waited for reserved publisher", 1, qr_waited);
    EXPECT("recovery retires only completed publishers", 0, qr_retired_writers);
    EXPECT("inflight setup reports overflow", 1, B.overflow); s2a_track_drain_done();
    for (unsigned i = 0; i <= RING; i++) s2a_track_reprotect((uint64_t)(p + i * 0x4000), 0x1000, S2A_TRACK_READ);
    // Overflow again, then write the already-scanned/reprotected page while the
    // recovery gate is closed. It must request the following conservative batch.
    for (unsigned i = 0; i <= RING; i++) *(volatile uint8_t *)(p + i * 0x4000) = 0x33;
    s2a_track_test_overflow_visited = qr_visited;
    drain(); EXPECT("scan-behind setup overflow", 1, B.overflow); s2a_track_drain_done();
    drain(); EXPECT("writer behind recovery scan requests next batch", 1, B.overflow);
    s2a_track_drain_done();
    s2a_track_reprotect((uint64_t)p, 0x1000, S2A_TRACK_READ); *(volatile uint8_t *)p = 0x77; drain();
    EXPECT("recovered page enqueues in normal next generation", 0, B.overflow);
    EXPECT("recovered page normal next generation delivered", 1, covers((uint64_t)p, 0x1000)); s2a_track_drain_done();
    EXPECT("recovery writer fixture retires tracker", 0, s2a_track_reset_session()); munmap(p, bytes);
}



static void t_ring_overflow(int sparse) {
    enum { N = RING + 9 }; // N written host pages + one protected but unwritten page.
    const size_t step = sparse ? 0x8000 : 0x4000;
    const size_t bytes = (N + 1) * step + 0x8000;
    uint8_t *p = mmap(NULL, bytes, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    EXPECT("overflow fixture mmap", 1, p != MAP_FAILED); if (p == MAP_FAILED) return;
    memset(p, 0x11, bytes);
    uint8_t *first = p + 0x4000;
    const unsigned subs = sparse ? 1 : 4;
    for (unsigned i = 0; i <= N; i++) s2a_track_reprotect((uint64_t)(first + i * step), subs * 0x1000, S2A_TRACK_READ);
    s2a_track_stat before, after; s2a_track_stats(&before);
    for (unsigned i = 0; i < N; i++) *(volatile uint8_t *)(first + i * step) = 0x22;
    drain(); s2a_track_stats(&after);
    EXPECT("overflow flagged", 1, B.overflow);
    EXPECT("overflow counter increments once", 1, after.overflows - before.overflows);
    for (unsigned i = 0; i <= N; i++) for (unsigned sub = 0; sub < subs; sub++) {
        char name[96]; snprintf(name, sizeof name, "overflow %s page %u/sub%u covered", sparse ? "sparse" : "contiguous", i, sub);
        EXPECT(name, 1, covers((uint64_t)(first + i * step + sub * 0x1000), 0x1000));
    }
    // Contiguous protections coalesce; sparse >RING ranges must fall back to one envelope.
    EXPECT("overflow one range after coalescing/envelope", 1, B.nranges);
    EXPECT("overflow range first byte", (uint64_t)first, B.nranges == 1 ? B.ranges[0].addr : 0);
    EXPECT("overflow range final protected byte", N * step + subs * 0x1000, B.nranges == 1 ? B.ranges[0].size : 0);
    s2a_track_drain_done();
    // The consumer later registers protection again when it needs tracking.
    // Recovery itself must not change the ordinary reprotection policy.
    s2a_track_reprotect((uint64_t)first, subs * 0x1000, S2A_TRACK_READ);
    EXPECT("consumer re-registers written page", PROT_READ, prot_of(first));
    uint64_t f0 = faults(); *(volatile uint8_t *)first = 0x33;
    EXPECT("same page faults again after overflow", 1, faults() - f0);
    drain();
    EXPECT("next drain not overflow", 0, B.overflow);
    EXPECT("same page re-enqueued and delivered", 1, covers((uint64_t)first, 0x1000));
    s2a_track_drain_done();
    s2a_track_reprotect((uint64_t)p, bytes, S2A_TRACK_RW);
    drain(); s2a_track_drain_done();
    munmap(p, bytes);
}
// A pending dirty notification is not permission to revive a revoked page.
static void t_overflow_revoked(int guest_none) {
    const size_t bytes = (RING + 4) * 0x4000;
    uint8_t *p = mmap(NULL, bytes, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    EXPECT("revoked fixture mmap", 1, p != MAP_FAILED); if (p == MAP_FAILED) return;
    memset(p, 0x11, bytes);
    s2a_track_reprotect((uint64_t)p, 0x1000, S2A_TRACK_READ);
    if (guest_none) EXPECT("guest PROT_NONE applied", 0, s2a_track_set_guest_protection((uint64_t)p, 0x4000, PROT_NONE));
    else { *(volatile uint8_t *)p = 0x22; s2a_track_reprotect((uint64_t)p, 0x1000, S2A_TRACK_RW); }
    for (unsigned i = 1; i <= RING + 1; i++) {
        uint8_t *a = p + i * 0x4000;
        s2a_track_reprotect((uint64_t)a, 0x1000, S2A_TRACK_READ); *(volatile uint8_t *)a = 0x33;
    }
    drain();
    EXPECT("revoked overflow flagged", 1, B.overflow);
    EXPECT(guest_none ? "overflow preserves guest NONE" : "overflow preserves revoked RW", guest_none ? PROT_NONE : PROT_READ | PROT_WRITE, prot_of(p));
    EXPECT("overflow does not resurrect revoked want", 0, s2a_track_sub_state((uint64_t)p) & 1);
    EXPECT("revoked protection keeps pending notification", 1, covers((uint64_t)p, 0x1000));
    s2a_track_drain_done();
    EXPECT("revoked fixture retires tracker", 0, s2a_track_reset_session());
    munmap(p, bytes);
}

// Guest permissions cancel native reprotection, not the pending notification
// required by prot_changed_page. Both ordinary and overflow batches must agree.
static void t_guest_notification(int overflow) {
    const size_t bytes = (RING + 3) * 0x4000;
    uint8_t *p = mmap(NULL, bytes, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    EXPECT("guest notification fixture mmap", 1, p != MAP_FAILED); if (p == MAP_FAILED) return;
    memset(p, 0x11, bytes);
    s2a_track_reprotect((uint64_t)p, 0x1000, S2A_TRACK_READ);
    EXPECT("guest changes actual permission to READ", 0, s2a_track_set_guest_protection((uint64_t)p, 0x4000, PROT_READ));
    if (overflow) for (unsigned i = 1; i <= RING + 1; i++) {
        uint8_t *a = p + i * 0x4000;
        s2a_track_reprotect((uint64_t)a, 0x1000, S2A_TRACK_READ); *(volatile uint8_t *)a = 0x22;
    }
    drain(); EXPECT("guest notification expected batch mode", overflow, B.overflow);
    EXPECT(overflow ? "overflow keeps external-permission dirty notification" : "ordinary keeps external-permission dirty notification", 1, covers((uint64_t)p, 0x1000));
    EXPECT("notification preserves actual guest READ", PROT_READ, prot_of(p));
    EXPECT("notification does not restore native want", 0, s2a_track_sub_state((uint64_t)p) & 1);
    s2a_track_drain_done(); EXPECT("guest notification fixture retires tracker", 0, s2a_track_reset_session()); munmap(p, bytes);
}

#endif

// 11-06 宿主替游戏写一个字不能被并发读成半截值（瓦力欧混响：DSP 写偏移 0x03C0→0x0780 读成 0x0380，读量 896 → abort）：
//   写线程经 s2a_track_write_untracked 交替写 4 字节 0x3C0 / 0x780（低两字节都变），读线程单条 32 位读；期望（手算）读到的只可能是这两个值，撕裂 0 次。
//   8 字节同理（0x3C0 / 0x780 放在低 4 字节、高 4 字节 0x11111111 / 0x22222222）。非对齐 4 字节仍走 memcpy，只核写完内容对
static _Atomic int tear_stop; static uint8_t *tear_p;
static void *tear_writer(void *x) { (void)x; uint64_t a = (uint64_t)(uintptr_t)tear_p;
    for (unsigned i = 0; !atomic_load(&tear_stop); i++) {
        uint32_t v = i & 1 ? 0x780 : 0x3C0; s2a_track_write_untracked(a, &v, 4, 0);
        uint64_t w = i & 1 ? 0x2222222200000780ull : 0x11111111000003C0ull; s2a_track_write_untracked(a + 8, &w, 8, 0);
    } return NULL; }
static void t_tear(void) {
    tear_p = mmap(NULL, 0x4000, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); memset(tear_p, 0, 0x4000);
    uint32_t v0 = 0x3C0; uint64_t w0 = 0x11111111000003C0ull; memcpy(tear_p, &v0, 4); memcpy(tear_p + 8, &w0, 8);
    pthread_t th; atomic_store(&tear_stop, 0); pthread_create(&th, NULL, tear_writer, NULL);
    unsigned long bad4 = 0, bad8 = 0, n = 0; uint32_t seen4 = 0; uint64_t seen8 = 0;
    for (; n < 20000000ul; n++) {
        uint32_t v = __atomic_load_n((uint32_t *)tear_p, __ATOMIC_RELAXED); if (v != 0x3C0 && v != 0x780) { bad4++; seen4 = v; }
        uint64_t w = __atomic_load_n((uint64_t *)(tear_p + 8), __ATOMIC_RELAXED); if (w != 0x11111111000003C0ull && w != 0x2222222200000780ull) { bad8++; seen8 = w; }
    }
    atomic_store(&tear_stop, 1); pthread_join(th, NULL);
    char m[200]; snprintf(m, sizeof m, "宿主写一个字不撕裂：%lu 次并发读，4 字节撕裂 %lu 次（例 0x%x）、8 字节撕裂 %lu 次（例 0x%llx）", n, bad4, seen4, bad8, (unsigned long long)seen8);
    printf("%s\n", m); EXPECT("宿主写一个字：4 字节撕裂次数", 0, bad4); EXPECT("宿主写一个字：8 字节撕裂次数", 0, bad8);
    uint32_t u = 0xA1B2C3D4; s2a_track_write_untracked((uint64_t)(uintptr_t)(tear_p + 0x101), &u, 4, 0);
    uint32_t r; memcpy(&r, tear_p + 0x101, 4); EXPECT("非对齐 4 字节照常写对", 0xA1B2C3D4, r);
    munmap(tear_p, 0x4000);
}
int main(void) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    if (getpagesize() != 0x4000) { printf("跳过：宿主页不是 16 KB\n"); return 0; }
    struct sigaction sa = {0}; sa.sa_sigaction = on_sig; sa.sa_flags = SA_SIGINFO; sigaction(SIGBUS, &sa, NULL); sigaction(SIGSEGV, &sa, NULL);
#if defined(RING) && RING == 64
    if (getenv("S2A_T_TRACK_ONLY_RING_PROTOCOL")) {
        t_overflow_publish();
#ifndef S2A_TRACK_TEST_OLD_RING
        t_overflow_recovery_writers();
#endif
        printf("t_track ring protocol：%d 项，失败 %d\n", count, fail); return fail != 0;
    }
    if (getenv("S2A_T_TRACK_ONLY_OVERFLOW")) {
        t_ring_overflow(0); t_ring_overflow(1);
        t_overflow_revoked(0); t_overflow_revoked(1); t_guest_notification(0); t_guest_notification(1);
        printf("t_track overflow：%d 项，失败 %d\n", count, fail); return fail != 0;
    }
#endif
    if (getenv("S2A_T_TRACK_ONLY_TEAR")) { t_tear(); printf("t_track 撕裂：%d 项，失败 %d\n", count, fail); return fail != 0; }
    if (getenv("S2A_T_TRACK_ONLY30")) { t30(); printf("t_track ㉚：%d 项，失败 %d\n", count, fail); return fail != 0; }
    t_session_retirement();
    t_tear();
    uint8_t *p = mmap(NULL, 0x8000, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); memset(p, 0x11, 0x8000);
    uint64_t b = (uint64_t)(uintptr_t)p, f0;
    // ① 第 0 页全部 4 个子页跟踪写（READ）；写子页 1 → 缺页一次；页已解开后再写子页 2（不缺页）
    s2a_track_reprotect(b, 0x4000, S2A_TRACK_READ);
    f0 = faults(); p[0x1000] = 0x22; p[0x2000] = 0x33;
    EXPECT("① 写子页 1、2：缺页次数", 1, faults() - f0);
    drain();
    EXPECT("① 排空：脏区间数（子页 1–2 连成一段）", 1, B.nranges);
    EXPECT("① 区间起点 = 子页 1", b + 0x1000, B.nranges ? B.ranges[0].addr : 0);
    EXPECT("① 区间长 = 2 个子页", 0x2000, B.nranges ? B.ranges[0].size : 0);
    // ② 子页 0、3 内容没变：已重设只读 → 再写子页 0 会缺页并报子页 0
    f0 = faults(); p[0] = 0x44;
    EXPECT("② 再写没变的子页 0：缺页次数（已重设只读）", 1, faults() - f0);
    drain();
    EXPECT("② 排空：区间 = 子页 0", b, B.nranges == 1 ? B.ranges[0].addr : 0);
    EXPECT("② 区间长", 0x1000, B.nranges == 1 ? B.ranges[0].size : 0);
    // ③ 不跟踪写（回写）子页 3：不报；排空后子页 3 重新只读 → CPU 再写子页 3 会缺页并报
    { static uint8_t f55[0x1000]; memset(f55, 0x55, sizeof f55); s2a_track_write_untracked(b + 0x3000, f55, 0x1000, 1); }
    drain();
    EXPECT("③ 不跟踪写子页 3 后排空：区间数", 0, B.nranges);
    f0 = faults(); p[0x3000] = 0x66;
    EXPECT("③ CPU 再写子页 3：缺页次数", 1, faults() - f0);
    drain();
    EXPECT("③ 排空：区间 = 子页 3", b + 0x3000, B.nranges == 1 ? B.ranges[0].addr : 0);
    // ④ 不在跟踪里的第 1 页：写了不报；跟踪写接口（C# Write）写跟踪页 = CPU 写，报
    p[0x4000] = 0x77; drain();
    EXPECT("④ 写未跟踪页：区间数", 0, B.nranges);
    s2a_track_write(b + 0x2010, 4); memset(p + 0x2010, 0x99, 4); drain();
    EXPECT("④ ① 报脏后没重设保护的子页 2：跟踪写不报（同原版 Dirty 期间不跟踪）", 0, B.nranges);
    s2a_track_reprotect(b + 0x2000, 0x1000, S2A_TRACK_READ); s2a_track_write(b + 0x2010, 4); memset(p + 0x2010, 0x98, 4); drain();
    EXPECT("④ 重设保护后跟踪写接口写子页 2：区间 = 子页 2", b + 0x2000, B.nranges == 1 ? B.ranges[0].addr : 0);
    { long rounds = 0, lost = race_run(1.0, S2A_TRACK_READ, &rounds);
      printf("（⑤ 并发 1 秒：写线程 %ld 轮）\n", rounds);
      EXPECT("⑤ 并发写观察中子页（READ）：漏报次数", 0, lost); }

    // ⑥–⑫ 子页 1 = GPU 改过（NONE），子页 2 = 跟踪写（READ）；内容全 0x11
    uint8_t *q = mmap(NULL, 0x4000, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); memset(q, 0x11, 0x4000); uint64_t c = (uint64_t)(uintptr_t)q;
    s2a_track_reprotect(c + 0x1000, 0x1000, S2A_TRACK_NONE); s2a_track_reprotect(c + 0x2000, 0x1000, S2A_TRACK_READ);
    // ⑥ 写 NONE 子页 1 个字节：缺页 1 次；排空不报普通区间（不触发回写），精确写 1 条 = 这 1 个字节
    f0 = faults(); q[0x1010] = 0xab;
    EXPECT("⑥ 写 NONE 子页：缺页次数", 1, faults() - f0);
    drain();
    EXPECT("⑥ 排空：普通区间数（不触发回写）", 0, B.nranges);
    EXPECT("⑥ 精确写条数", 1, B.nprecise);
    EXPECT("⑥ 精确写子页 = 子页 1", c + 0x1000, B.nprecise ? B.precise[0].addr : 0);
    EXPECT("⑥ 位图：只有第 0x10 字节", 1, B.nprecise ? popc(&B.precise[0]) * bit(&B.precise[0], 0x10) : 0);
    // ⑦ 同子页多次写：第一次缺页（排空后已重设只读），之后页可写不缺页；写 0x1020、0x1030–0x1033，再写 1 个与旧值相同的字节 0x1100（已知盲区：不报）
    f0 = faults(); q[0x1020] = 0x01; q[0x1030] = 0x02; q[0x1031] = 0x03; q[0x1032] = 0x04; q[0x1033] = 0x05; q[0x1100] = 0x11;
    EXPECT("⑦ 排空后重新只读：缺页次数", 1, faults() - f0);
    drain();
    EXPECT("⑦ 精确写条数", 1, B.nprecise);
    EXPECT("⑦ 位图字节数（相同值的写不算）", 5, B.nprecise ? popc(&B.precise[0]) : -1);
    EXPECT("⑦ 位图含 0x20 与 0x30–0x33、不含 0x100", 1, B.nprecise ? bit(&B.precise[0], 0x20) & bit(&B.precise[0], 0x30) & bit(&B.precise[0], 0x33) & !bit(&B.precise[0], 0x100) : 0);
    // ⑧ 同一批里既有精确写（子页 1）又有普通脏子页（子页 2）：两张表同批交出（C# 先处理精确写、再处理区间）
    q[0x2008] = 0x07; q[0x1040] = 0x08;
    drain();
    EXPECT("⑧ 普通区间 = 子页 2", c + 0x2000, B.nranges == 1 ? B.ranges[0].addr : 0);
    EXPECT("⑧ 精确写 = 子页 1 的 0x40 一个字节", 1, B.nprecise == 1 ? popc(&B.precise[0]) * bit(&B.precise[0], 0x40) : 0);
    // ⑨ 不跟踪写（回写前 8 字节）与游戏写交错：回写之后游戏再写 0x1100（页可写不缺页）→ 排空只报游戏写的 1 字节（回写字节是 GPU 自己的数据，不当 CPU 写重报），内存里两者都在
    { uint8_t cc[8]; memset(cc, 0xcc, 8); s2a_track_write_untracked(c + 0x1000, cc, 8, 1); } q[0x1100] = 0xdd;
    drain();
    EXPECT("⑨ 位图字节数（只有游戏写的 1 个）", 1, B.nprecise == 1 ? popc(&B.precise[0]) : -1);
    EXPECT("⑨ 游戏写的字节在位图里", 1, B.nprecise == 1 ? bit(&B.precise[0], 0x100) : 0);
    EXPECT("⑨ 回写的字节在", 0xcc, q[0x1000]);
    EXPECT("⑨ 游戏写的值", 0xdd, q[0x1100]);
    // ⑩ Ryujinx 把子页 1 改为 READ：再写走普通区间、不报精确写
    s2a_track_reprotect(c + 0x1000, 0x1000, S2A_TRACK_READ); q[0x1200] = 0x09;
    drain();
    EXPECT("⑩ 改回 READ 后写：精确写条数", 0, B.nprecise);
    EXPECT("⑩ 改回 READ 后写：普通区间 = 子页 1", c + 0x1000, B.nranges == 1 ? B.ranges[0].addr : 0);
    // ⑪ 回写与游戏写交错：子页 3 = NONE；游戏先写 0x3100（未报）→ 回写整子页 0xee → 回写写完 → 0x3100 放回游戏的值、其余是回写数据
    s2a_track_reprotect(c + 0x3000, 0x1000, S2A_TRACK_NONE); q[0x3100] = 0x5a;
    { static uint8_t fe[0x1000]; memset(fe, 0xee, sizeof fe); s2a_track_write_untracked(c + 0x3000, fe, 0x1000, 1); }
    EXPECT("⑪ 回写后游戏先写的字节 = 游戏的值", 0x5a, q[0x3100]);
    EXPECT("⑪ 其余字节 = 回写数据", 0xee, q[0x30ff]);
    drain();
    { const s2a_track_precise *r = rec_at(c + 0x3000); EXPECT("⑪ 排空：子页 3 位图只有游戏写的那个字节", 1, r ? bit(r, 0x100) * popc(r) : 0); }
    // ⑫ 信号量写（flush = 0）：游戏先写 0x3200，再不跟踪写同一处 4 字节 → 以后者（时间上晚）为准：值不放回，排空也不把它当 CPU 写报
    q[0x3200] = 0x6b;
    { uint8_t sv[4] = {0x01, 0x02, 0x03, 0x04}; s2a_track_write_untracked(c + 0x3200, sv, 4, 0); }
    EXPECT("⑫ 信号量写之后的值不被放回", 0x01, q[0x3200]);
    drain();
    { const s2a_track_precise *r = rec_at(c + 0x3000); EXPECT("⑫ 排空：子页 3 无精确写（游戏写被信号量盖掉）", 0, r ? popc(r) : 0); }
    // ⑯ 对拍找到的漏报（旧设计「回写后重设只读不比内容」）：READ 子页先被信号量写解开整页，排空前游戏又写同一子页（页可写不缺页）→ 排空必须报
    s2a_track_reprotect(c + 0x2000, 0x1000, S2A_TRACK_READ); drain();
    { uint8_t sv[4] = {9, 9, 9, 9}; s2a_track_write_untracked(c + 0x2100, sv, 4, 0); } q[0x2200] = 0x42;
    drain();
    EXPECT("⑯ 信号量写后游戏写同一 READ 子页：区间 = 子页 2", c + 0x2000, B.nranges == 1 ? B.ranges[0].addr : 0);

    // ⑬ 一次排空交整批：NONE 区 8 个子页（2 个宿主页），每子页按旧库暗黑2 碎写形状写 3 段各 5 字节、段间隔 3 字节 → 1 次排空 8 条、每条 15 字节，没有逐段回调
    { uint8_t *r = mmap(NULL, 0x8000, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); memset(r, 0, 0x8000); uint64_t rb = (uint64_t)(uintptr_t)r;
      s2a_track_reprotect(rb, 0x8000, S2A_TRACK_NONE);
      for (int s = 0; s < 8; s++) for (int k = 0; k < 3; k++) memset(r + s * 0x1000 + 0x100 + k * 8, 0x5c, 5);
      drain();
      int ok = B.nprecise == 8 && B.nranges == 0; for (uint32_t i = 0; ok && i < 8; i++) ok = popc(&B.precise[i]) == 15 && bit(&B.precise[i], 0x100) && !bit(&B.precise[i], 0x105) && bit(&B.precise[i], 0x108);
      EXPECT("⑬ 一次排空：精确写 8 条、每条 15 字节、间隙不并入", 1, ok);
      s2a_track_reprotect(rb, 0x8000, S2A_TRACK_RW); drain(); munmap(r, 0x8000); }

    // ⑭ 快照槽满（块数上限压到 1 块 = 8192 槽）：NONE 区 2050 个宿主页 = 8200 个子页，逐子页各写 1 字节 → 前 2048 页（8192 子页）拍快照，最后 2 页 8 个子页退回普通脏子页、逐次报红
    s2a_track_test_snap_chunks(1);
    { size_t n = 2050ull * 0x4000; uint8_t *r = mmap(NULL, n, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); memset(r, 0, n); uint64_t rb = (uint64_t)(uintptr_t)r;
      s2a_track_stat s0, s1; s2a_track_stats(&s0);
      s2a_track_reprotect(rb, n, S2A_TRACK_NONE);
      for (size_t s = 0; s < n / 0x1000; s++) r[s * 0x1000] = 1;
      drain(); s2a_track_stats(&s1);
      EXPECT("⑭ 槽满：精确写条数", 8192, B.nprecise);
      EXPECT("⑭ 槽满：退回次数（计数报红）", 8, s1.pfull - s0.pfull);
      EXPECT("⑭ 槽满：退回的 8 子页合成 1 段普通区间", 1, B.nranges);
      EXPECT("⑭ 区间 = 最后 2 页", rb + 2048ull * 0x4000, B.nranges == 1 ? B.ranges[0].addr : 0);
      EXPECT("⑭ 区间长", 0x8000, B.nranges == 1 ? B.ranges[0].size : 0);
      s2a_track_reprotect(rb, n, S2A_TRACK_RW); drain(); munmap(r, n); }
    // ⑭b 按需增长（块数上限 8）：同样 8200 个子页 → 全部拍快照、0 退回、0 普通区间；块数增到 ≥ 2、同时占用峰值 ≥ 8200；
    //   排空后附加块整块空了 → 交还物理页 ≥ 1 次；再写一轮照样全拍（交还后的块能再用）
    s2a_track_test_snap_chunks(8);
    { size_t n = 2050ull * 0x4000; uint8_t *r = mmap(NULL, n, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); memset(r, 0, n); uint64_t rb = (uint64_t)(uintptr_t)r;
      s2a_track_stat s0, s1, s2; s2a_track_stats(&s0);
      s2a_track_reprotect(rb, n, S2A_TRACK_NONE);
      for (size_t s = 0; s < n / 0x1000; s++) r[s * 0x1000] = 1;
      drain(); s2a_track_stats(&s1);
      EXPECT("⑭b 增长：精确写条数", 8200, B.nprecise);
      EXPECT("⑭b 增长：退回次数", 0, s1.pfull - s0.pfull);
      EXPECT("⑭b 增长：普通区间", 0, B.nranges);
      EXPECT("⑭b 增长：块数 ≥ 2", 1, s1.snap_chunks >= 2);
      EXPECT("⑭b 增长：占用峰值 ≥ 8200", 1, s1.snap_peak >= 8200);
      EXPECT("⑭b 排空后附加块交还物理页", 1, s1.snap_freed > s0.snap_freed);
      s2a_track_reprotect(rb, n, S2A_TRACK_NONE);
      for (size_t s = 0; s < n / 0x1000; s++) r[s * 0x1000] = 2;
      drain(); s2a_track_stats(&s2);
      EXPECT("⑭b 交还后再写一轮：精确写条数", 8200, B.nprecise);
      EXPECT("⑭b 交还后再写一轮：退回次数", 0, s2.pfull - s1.pfull);
      s2a_track_reprotect(rb, n, S2A_TRACK_RW); drain(); munmap(r, n); }

    { long rounds = 0, lost = race_run(1.0, S2A_TRACK_NONE, &rounds);
      printf("（⑮ 并发 1 秒：写线程 %ld 轮）\n", rounds);
      EXPECT("⑮ 并发写 NONE 子页：漏报次数", 0, lost); }
    // ⑰ 同值写：内存原值 0、GPU 侧 0xFF，子页 1 标 GPU 改过；游戏写 [0x1010] = 0（与内存旧值同）
    for (int path = 0; path < 2; path++) {   // 0 = A 方案（登记回调、游戏路径），1 = 旧路径反证（不登记，排空时照 NxTrack.Drain 合并）
        uint8_t *r = mmap(NULL, 0x4000, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); memset(r, 0, 0x4000); g_gb = (uint64_t)(uintptr_t)r; memset(g_gpu, 0xff, sizeof g_gpu);
        s2a_track_prot_changed(g_gb, 0x4000);   // 新 mmap 可能落在前面测试 munmap 掉的地址上：先把跟踪表里这片的状态同步成「外部改过、可写」
        drain(); s2a_track_reprotect(g_gb + 0x1000, 0x1000, S2A_TRACK_NONE);
        s2a_track_set_touch(path == 0 ? ryu_touch : NULL); g_guest = 1;
        *(volatile uint8_t *)(r + 0x1010) = 0;
        g_guest = 0; drain();
        if (path == 1) for (uint32_t i = 0; i < B.nprecise; i++) {   // = NxTrack.Drain：取 CPU 现内容 → 回写 GPU 数据 → 位图里的字节放回
            uint8_t cpu[0x1000]; memcpy(cpu, (void *)B.precise[i].addr, 0x1000); ryu_touch(B.precise[i].addr, 0x1000, 1);
            for (unsigned k = 0; k < 0x1000; k++) if (bit(&B.precise[i], k)) ((uint8_t *)B.precise[i].addr)[k] = cpu[k]; }
        // 同值写在旧路径里认不出、没上报：Ryujinx 仍当 GPU 数据是最新的，之后任何一次回写（CPU 读 / GPU 同步）都会把它写进内存
        if (path == 1) ryu_touch(g_gb + 0x1000, 0x1000, 0);
        volatile uint8_t *v = r;   // 内存由信号处理 / 回调改，读时不许编译器按 memset 的值折叠
        if (path == 0) { EXPECT("⑰ A 方案：同值写的字节 = CPU 写的 0", 0, v[0x1010]); EXPECT("⑰ A 方案：CPU 没写的字节 = GPU 回写的 0xFF", 0xff, v[0x1011]); }
        else EXPECT("⑰ 反证（旧路径排空合并）：同值写的字节被盖成 GPU 的 0xFF", 0xff, v[0x1010]);
        s2a_track_set_touch(NULL); s2a_track_reprotect(g_gb, 0x4000, S2A_TRACK_RW); drain(); munmap(r, 0x4000);
    }
    // ⑱ 解除映射：不登记回调（走快照路径），游戏写子页 1 一个变了的字节 → 快照待比对；Ryujinx 改不跟踪 → 排空
    { uint8_t *r = mmap(NULL, 0x4000, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); memset(r, 0, 0x4000); uint64_t rb = (uint64_t)(uintptr_t)r;
      s2a_track_prot_changed(rb, 0x4000); drain();
      s2a_track_reprotect(rb + 0x1000, 0x1000, S2A_TRACK_NONE);
      *(volatile uint8_t *)(r + 0x1020) = 7;
      s2a_track_reprotect(rb + 0x1000, 0x1000, S2A_TRACK_RW);   // 解除映射 / 释放
      drain();
      EXPECT("⑱ 解除映射后排空：该子页精确写条数", 0, rec_at(rb + 0x1000) ? 1 : 0);
      drain(); munmap(r, 0x4000); }
    // ⑲ 托管写：子页 1 内存 0、GPU 侧 0xFF；托管代码写 [0x1030] = 0（同值）前调 s2a_track_write
    { uint8_t *r = mmap(NULL, 0x4000, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); memset(r, 0, 0x4000); g_gb = (uint64_t)(uintptr_t)r; memset(g_gpu, 0xff, sizeof g_gpu);
      s2a_track_prot_changed(g_gb, 0x4000); drain();
      s2a_track_reprotect(g_gb + 0x1000, 0x1000, S2A_TRACK_NONE);
      s2a_track_set_touch(ryu_touch);
      s2a_track_write(g_gb + 0x1030, 1); r[0x1030] = 0;
      volatile uint8_t *v = r;
      EXPECT("⑲ 回写自身的托管写不再触发回写：回调最深层数", 1, g_touch_maxdepth);
      EXPECT("⑲ 托管写：写的字节 = CPU 的 0", 0, v[0x1030]); EXPECT("⑲ 托管写：没写的字节 = GPU 回写的 0xFF", 0xff, v[0x1031]);
      s2a_track_set_touch(NULL); s2a_track_reprotect(g_gb, 0x4000, S2A_TRACK_RW); drain(); munmap(r, 0x4000); }
    // ㉒ 回写在另一条线程：不跟踪托管写（s2a_track_write_quiet，Ryujinx GetWritableRegion(tracked: false)）不再触发回写，回调 1 层；
    //    反证：同样在另一条线程走跟踪托管写（s2a_track_write，修前 GetWritableRegion 不分跟踪与否）——t_in_touch 挡不住，再触发（真机上即同一 RegionHandle 锁死锁）
    for (int quiet = 1; quiet >= 0; quiet--) {
      uint8_t *r = mmap(NULL, 0x4000, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); memset(r, 0, 0x4000); g_gb = (uint64_t)(uintptr_t)r; memset(g_gpu, 0xff, sizeof g_gpu);
      s2a_track_prot_changed(g_gb, 0x4000); drain();
      s2a_track_reprotect(g_gb + 0x1000, 0x1000, S2A_TRACK_NONE);
      g_touch_maxdepth = 0; g_touch_depth = 0; g_xw = quiet ? s2a_track_write_quiet : s2a_track_write; s2a_track_set_touch(ryu_touch_x);
      s2a_track_write(g_gb + 0x1030, 1); r[0x1030] = 0;
      volatile uint8_t *v = r;
      if (quiet) {
        EXPECT("㉒ 回写在另一条线程、不跟踪托管写：回调最深层数", 1, g_touch_maxdepth);
        EXPECT("㉒ 没写的字节 = GPU 回写的 0xFF", 0xff, v[0x1031]);
      } else EXPECT("㉒ 反证：另一条线程走跟踪托管写会再触发回写（层数 > 1）", 1, g_touch_maxdepth > 1);
      s2a_track_set_touch(NULL); s2a_track_reprotect(g_gb, 0x4000, S2A_TRACK_RW); drain(); munmap(r, 0x4000); }
    // ⑳ 写邻居子页：子页 1 GPU 改过、游戏写子页 2（不是 GPU 改过的）→ 不触发回写；子页 1 仍是 GPU 侧数据（没被读回盖掉）
    { uint8_t *r = mmap(NULL, 0x4000, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); memset(r, 0, 0x4000); g_gb = (uint64_t)(uintptr_t)r; memset(g_gpu, 0xff, sizeof g_gpu);
      s2a_track_prot_changed(g_gb, 0x4000); drain();
      s2a_track_reprotect(g_gb + 0x1000, 0x1000, S2A_TRACK_NONE); s2a_track_reprotect(g_gb + 0x2000, 0x1000, S2A_TRACK_READ);
      g_touch_maxdepth = 0; s2a_track_set_touch(ryu_touch); g_guest = 1;
      *(volatile uint8_t *)(r + 0x2010) = 5;
      g_guest = 0;
      volatile uint8_t *v = r;
      EXPECT("⑳ 写邻居子页：不回写（回调层数 0）", 0, g_touch_maxdepth); EXPECT("⑳ 写邻居子页：写入生效", 5, v[0x2010]); EXPECT("⑳ GPU 改过的子页未被回写盖（仍为 0）", 0, v[0x1010]);
      s2a_track_set_touch(NULL); s2a_track_reprotect(g_gb, 0x4000, S2A_TRACK_RW); drain(); munmap(r, 0x4000); }
    // ㉑ READFLUSH：子页 1 内存 0、GPU 侧 0xAB；子页 2 只跟踪写
    for (int on = 1; on >= 0; on--) {
      uint8_t *r = mmap(NULL, 0x4000, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); memset(r, 0, 0x4000); g_gb = (uint64_t)(uintptr_t)r; memset(g_gpu, 0xab, sizeof g_gpu);
      s2a_track_set_readflush(on); s2a_track_prot_changed(g_gb, 0x4000); drain();
      s2a_track_reprotect(g_gb + 0x1000, 0x1000, S2A_TRACK_NONE); s2a_track_reprotect(g_gb + 0x2000, 0x1000, S2A_TRACK_READ);
      volatile uint8_t *v = r; char nm[96];
      snprintf(nm, sizeof nm, "㉑ 开关%s：GPU 改过子页所在页的保护", on ? "开" : "关"); EXPECT(nm, on ? VM_PROT_NONE : VM_PROT_READ, prot_of(r));
      g_touch_n = g_touch_w = 0; s2a_track_set_touch(ryu_touch); g_guest = 1;
      uint8_t got = v[0x1010];
      g_guest = 0;
      snprintf(nm, sizeof nm, "㉑ 开关%s：游戏读 GPU 改过的子页读到的值", on ? "开" : "关"); EXPECT(nm, on ? 0xab : 0, got);
      snprintf(nm, sizeof nm, "㉑ 开关%s：回写回调次数（按读）", on ? "开" : "关"); EXPECT(nm, on ? 1 : 0, g_touch_n); if (on) EXPECT("㉑ 开关开：回写按读事件（写事件 0）", 0, g_touch_w);
      if (on) {
        EXPECT("㉑ 开关开：回写后页降回只读", VM_PROT_READ, prot_of(r));
        // 同页别的子页：子页 1 再标 GPU 改过、GPU 侧改 0xCD；游戏读子页 2 也先回写整页
        memset(g_gpu, 0xcd, sizeof g_gpu); s2a_track_reprotect(g_gb + 0x1000, 0x1000, S2A_TRACK_NONE); g_touch_n = 0; g_guest = 1;
        uint8_t g2 = v[0x2010]; (void)g2;
        g_guest = 0;
        EXPECT("㉑ 开关开：游戏读同页别的子页也回写（回调次数）", 1, g_touch_n); EXPECT("㉑ 开关开：子页 1 已是 GPU 的 0xCD", 0xcd, v[0x1010]);
        // 宿主读：子页 1 再标 GPU 改过、GPU 侧 0xEF；宿主代码读不改道、不回写
        memset(g_gpu, 0xef, sizeof g_gpu); s2a_track_reprotect(g_gb + 0x1000, 0x1000, S2A_TRACK_NONE); g_touch_n = 0;
        drain();   // 先排空：上一步回写的托管写把这页登记进了脏页环，不清掉的话下面「排空设回不可读」会被 settle 顺带做掉、验不到宿主读这条路
        EXPECT("㉑ 开关开：宿主读前页不可读", VM_PROT_NONE, prot_of(r));
        uint8_t h = v[0x1010];
        EXPECT("㉑ 开关开：宿主读不回写（回调次数）", 0, g_touch_n); EXPECT("㉑ 开关开：宿主读到内存旧值 0xCD", 0xcd, h); EXPECT("㉑ 开关开：宿主读后页只读", VM_PROT_READ, prot_of(r));
        // 宿主读放开的页：下次排空设回不可读（GPU 改过子页还在），之后游戏读照常先回写（改前一直可读、游戏读到旧值 0xCD）
        drain();
        EXPECT("㉑ 开关开：宿主读放开后排空设回不可读", VM_PROT_NONE, prot_of(r));
        g_touch_n = 0; g_guest = 1;
        uint8_t g3 = v[0x1010];
        g_guest = 0;
        EXPECT("㉑ 开关开：设回后游戏读先回写（回调次数）", 1, g_touch_n); EXPECT("㉑ 开关开：设回后游戏读到 GPU 的 0xEF", 0xef, g3);
        // 排空落地读不可读页：子页 2（只跟踪写）解开后进观察中，子页 1 再标 GPU 改过 → 页不可读；排空要读子页 2 内容比哈希，不得自己缺页崩
        s2a_track_reprotect(g_gb + 0x2000, 0x1000, S2A_TRACK_READ); s2a_track_write(g_gb + 0x3000, 1); r[0x3000] = 1;   // 解开整页：子页 2 随之进观察中
        s2a_track_reprotect(g_gb + 0x1000, 0x1000, S2A_TRACK_NONE);
        s2a_track_stat s0, s1; s2a_track_stats(&s0); drain(); s2a_track_stats(&s1);
        EXPECT("㉑ 开关开：排空落地读不可读页不靠缺页兜底（宿主读次数增量）", 0, s1.rf_hostread - s0.rf_hostread);
        EXPECT("㉑ 开关开：排空落地读完后页仍不可读（GPU 改过子页还在）", VM_PROT_NONE, prot_of(r));
      }
      s2a_track_set_touch(NULL); s2a_track_set_readflush(0); s2a_track_reprotect(g_gb, 0x4000, S2A_TRACK_RW); drain(); munmap(r, 0x4000);
    }
    // ㉓ 过期缺页：线程 B 写只读页、内核已投递缺页但处理函数还没跑（被抢占）；其间 Ryujinx 线程把整页改不跟踪（reprotect RW，页已真可写）。
    //    B 的处理函数晚到 20 ms 才跑 → 只是重执行：不按「状态可写却缺页」自愈、不整页报脏（这页 Ryujinx 已不跟踪），算一次竞争。
    //    反证（改前 track.c）：按「最近一次缺页解开」的时刻判竞争，reprotect RW 不更新那个时刻、晚到 >10 ms 也超窗 → 自愈 +1、整页 4 子页报脏、报红
    { uint8_t *r = mmap(NULL, 0x4000, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); memset(r, 0, 0x4000); uint64_t rb = (uint64_t)(uintptr_t)r;
      s2a_track_prot_changed(rb, 0x4000); drain();
      s2a_track_reprotect(rb, 0x4000, S2A_TRACK_READ);
      EXPECT("㉓ 跟踪写后页只读", VM_PROT_READ, prot_of(r));
      s2a_track_reprotect(rb, 0x4000, S2A_TRACK_RW);
      EXPECT("㉓ 改不跟踪后页可读写", VM_PROT_READ | VM_PROT_WRITE, prot_of(r));
      usleep(20000);
      s2a_track_stat s0, s1; s2a_track_stats(&s0);
      int rr = s2a_track_fault(r + 0x1010, 1);
      s2a_track_stats(&s1); drain();
      int nr = 0; for (uint32_t i = 0; i < B.nranges; i++) if (B.ranges[i].addr < rb + 0x4000 && B.ranges[i].addr + B.ranges[i].size > rb) nr++;
      EXPECT("㉓ 过期缺页：认领、重执行（返回 1）", 1, rr);
      EXPECT("㉓ 过期缺页：不自愈（自愈增量）", 0, s1.heals - s0.heals);
      EXPECT("㉓ 过期缺页：算竞争（竞争增量）", 1, s1.races - s0.races);
      EXPECT("㉓ 过期缺页：不报脏区间", 0, nr);
      EXPECT("㉓ 过期缺页后页仍可读写", VM_PROT_READ | VM_PROT_WRITE, prot_of(r));
      // 正对照（安全阀仍在）：跟踪表记可写、本模块之外有人把页改成只读且没报 prot_changed → 游戏真写 → 自愈 +1、写生效、整页报脏
      mprotect(r, 0x4000, PROT_READ); usleep(20000); s2a_track_stats(&s0);
      *(volatile uint8_t *)(r + 0x2020) = 9;
      s2a_track_stats(&s1); drain();
      nr = 0; for (uint32_t i = 0; i < B.nranges; i++) if (B.ranges[i].addr < rb + 0x4000 && B.ranges[i].addr + B.ranges[i].size > rb) nr += (int)(B.ranges[i].size / 0x1000);
      EXPECT("㉓ 正对照：外部改只读后真写 → 自愈增量", 1, s1.heals - s0.heals);
      EXPECT("㉓ 正对照：写入生效", 9, ((volatile uint8_t *)r)[0x2020]);
      EXPECT("㉓ 正对照：整页 4 子页报脏", 4, nr);
      drain(); munmap(r, 0x4000); }
    // ㉟ 客人 SetMemoryPermission 收成只读之后真写（审计 #806 第 1 条 F-apple-ro-heal）：外部报过的改保护（lastp 0xfe）不是本模块漏报，
    //    缺页不许自愈改回可写——苹果原先只看「状态可写、内核不可写」就升权，客人刚设的只读被改回、写成功、整页按脏。
    //    两条路都核：A = s2a_track_set_guest_protection（SetMemoryPermission 走的钩子，先占页再 mprotect）；B = 先 mprotect 再 s2a_track_prot_changed（原苹果 svc_mem 写法）
    for (int via = 0; via < 2; via++) {
      uint8_t *r = mmap(NULL, 0x4000, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); memset(r, 0, 0x4000); uint64_t rb = (uint64_t)(uintptr_t)r;
      s2a_track_prot_changed(rb, 0x4000); drain();
      s2a_track_reprotect(rb, 0x4000, S2A_TRACK_READ); s2a_track_reprotect(rb, 0x4000, S2A_TRACK_RW); drain();   // 这页已有叶子、本模块设过保护
      if (via == 0) s2a_track_set_guest_protection(rb, 0x4000, PROT_READ);
      else { mprotect(r, 0x4000, PROT_READ); s2a_track_prot_changed(rb, 0x4000); }
      usleep(20000);
      s2a_track_stat s0, s1; s2a_track_stats(&s0);
      int r1 = s2a_track_fault(r + 0x10, 1), r2 = s2a_track_fault(r + 0x10, 1);   // 第一次允许当过期重执行，第二次必须交回（客人真写了只读页）
      s2a_track_stats(&s1); drain();
      EXPECT(via ? "㉟ B 先 mprotect 再报：只读后真写不自愈（自愈增量）" : "㉟ A 走客人改保护钩子：只读后真写不自愈（自愈增量）", 0, s1.heals - s0.heals);
      EXPECT(via ? "㉟ B：第二次缺页交回（返回 0）" : "㉟ A：第二次缺页交回（返回 0）", 0, r2);
      EXPECT(via ? "㉟ B：页仍只读" : "㉟ A：页仍只读", VM_PROT_READ, prot_of(r));
      (void)r1; s2a_track_prot_changed(rb, 0x4000); drain(); munmap(r, 0x4000);
    }
    // ㉔ 不跟踪小写落在观察中子页（常量缓冲内联更新的常态）：只按字增量改基线，不整页算哈希；语义不变——
    //    写本身不报；之前 CPU 在同子页别处的写照样报；之后 CPU 的写照样报。反证：修前每次写前写后各整页算一次（8192 字节）
    { uint8_t *r = mmap(NULL, 0x4000, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); memset(r, 0, 0x4000); uint64_t rb = (uint64_t)(uintptr_t)r;
      s2a_track_prot_changed(rb, 0x4000); drain();
      s2a_track_reprotect(rb, 0x4000, S2A_TRACK_READ);
      r[0x3000] = 1; drain(); s2a_track_reprotect(rb + 0x3000, 0x1000, S2A_TRACK_READ);   // 解开整页：子页 0–2 进观察中（基线 = 写前内容），子页 3 报脏后重设
      r[0x3004] = 1;   // 页仍可写（观察中子页还没落地）：再解开一次让 0–2 持续观察——这次写报子页 3
      uint8_t sv[24]; memset(sv, 0x5a, sizeof sv);
      uint64_t h0 = s2a_track_hash_bytes(); s2a_track_write_untracked(rb + 0x1010, sv, 24, 0); uint64_t h1 = s2a_track_hash_bytes();
      EXPECT("㉔ 观察中子页上 24 字节不跟踪写：算哈希字节数（≤ 64，修前 8192）", 1, h1 - h0 <= 64);
      drain();
      EXPECT("㉔ 只有不跟踪写的子页 1：不报（区间 / 精确写条数）", 0, rec_at(rb + 0x1000) != NULL || (B.nranges && B.ranges[0].addr == rb + 0x1000));
      // 之前 CPU 写同子页别处 + 之后不跟踪写：CPU 那笔要报
      s2a_track_reprotect(rb, 0x4000, S2A_TRACK_READ); r[0x3008] = 1;   // 解开整页，子页 1 进观察中
      r[0x1800] = 7; s2a_track_write_untracked(rb + 0x1010, sv, 24, 0); drain();
      int rep1 = 0; for (uint32_t i = 0; i < B.nranges; i++) if (B.ranges[i].addr <= rb + 0x1000 && rb + 0x1000 < B.ranges[i].addr + B.ranges[i].size) rep1 = 1;
      EXPECT("㉔ CPU 先写子页 1 别处、再不跟踪写：子页 1 报脏", 1, rep1);
      // 不跟踪写之后 CPU 再写同子页：要报
      s2a_track_reprotect(rb, 0x4000, S2A_TRACK_READ); r[0x300c] = 1;
      s2a_track_write_untracked(rb + 0x1010, sv, 24, 0); r[0x1900] = 9; drain();
      rep1 = 0; for (uint32_t i = 0; i < B.nranges; i++) if (B.ranges[i].addr <= rb + 0x1000 && rb + 0x1000 < B.ranges[i].addr + B.ranges[i].size) rep1 = 1;
      EXPECT("㉔ 不跟踪写之后 CPU 再写子页 1：子页 1 报脏", 1, rep1);
      EXPECT("㉔ 不跟踪写内容在", 0x5a, r[0x1027]);
      s2a_track_reprotect(rb, 0x4000, S2A_TRACK_RW); drain(); munmap(r, 0x4000); }
    // ㉔ s2a_track_gpu_modified：子页 1 GPU 改过（None）、子页 2 只跟踪写；游戏写子页 2 解开整页后，子页 1 仍要报「有 GPU 改过」
    //    （反证：按 act & want 判，解开后 want 清零，漏看 → 怪猎内联更新发普通写事件、先回写 2923 次）
    { uint8_t *r = mmap(NULL, 0x4000, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); memset(r, 0, 0x4000); uint64_t rb = (uint64_t)(uintptr_t)r;
      s2a_track_prot_changed(rb, 0x4000); drain();
      s2a_track_reprotect(rb + 0x1000, 0x1000, S2A_TRACK_NONE); s2a_track_reprotect(rb + 0x2000, 0x1000, S2A_TRACK_READ);
      EXPECT("㉔ 页受保护时：子页 1 有 GPU 改过 / 子页 2 没有", 10, s2a_track_gpu_modified(rb + 0x1010, 8) * 10 + s2a_track_gpu_modified(rb + 0x2010, 8));
      r[0x2010] = 3;   // 解开整页
      EXPECT("㉔ 页被解开后：子页 1 仍有 GPU 改过 / 子页 2 没有", 10, s2a_track_gpu_modified(rb + 0x1010, 8) * 10 + s2a_track_gpu_modified(rb + 0x2010, 8));
      s2a_track_reprotect(rb + 0x1000, 0x1000, S2A_TRACK_READ);
      EXPECT("㉔ Ryujinx 改回只跟踪写后：子页 1 没有", 0, s2a_track_gpu_modified(rb + 0x1010, 8));
      s2a_track_reprotect(rb, 0x4000, S2A_TRACK_RW); drain(); munmap(r, 0x4000); }
    // ㉕ 定向读时回写（s2a_track_mark_readflush）：全局 READFLUSH 关，只登记页 A。A、B 两页子页 1 都 GPU 改过（内存 0、GPU 侧 0xAB）。
    //    期望按 ㉑ 的语义手算：A 不可读、游戏读先回写 1 次读到 0xAB；B 未登记 = 缺省「免读回」：只读、游戏读不回写、读到旧值 0。
    //    再测先登记后被 GPU 改：A 子页 1 改回只跟踪写（页只读）→ 再标 GPU 改过、GPU 侧 0xCD → A 随即不可读，游戏读到 0xCD。
    //    放在最后：登记标记留在页表叶子里，不影响前面各项
    { uint8_t *r = mmap(NULL, 0x8000, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); memset(r, 0, 0x8000); uint64_t ra = (uint64_t)(uintptr_t)r, rb = ra + 0x4000;
      g_gb = ra; memset(g_gpu, 0xab, sizeof g_gpu);
      s2a_track_set_readflush(0); s2a_track_prot_changed(ra, 0x8000); drain();
      s2a_track_reprotect(ra + 0x1000, 0x1000, S2A_TRACK_NONE); s2a_track_reprotect(rb + 0x1000, 0x1000, S2A_TRACK_NONE);
      EXPECT("㉕ 登记前：A 页只读（全局关 = 缺省）", VM_PROT_READ, prot_of(r));
      s2a_track_mark_readflush(ra + 0x1010, 8);
      EXPECT("㉕ 登记后：A 页不可读", VM_PROT_NONE, prot_of(r)); EXPECT("㉕ 登记后：未登记的 B 页仍只读", VM_PROT_READ, prot_of(r + 0x4000));
      volatile uint8_t *v = r; g_touch_n = g_touch_w = 0; s2a_track_set_touch(ryu_touch); g_guest = 1;
      uint8_t ga = v[0x1010];
      g_guest = 0;
      EXPECT("㉕ 游戏读 A：先回写（回调次数）", 1, g_touch_n); EXPECT("㉕ 游戏读 A：读到 GPU 的 0xAB", 0xab, ga);
      g_gb = rb; g_touch_n = 0; g_guest = 1;
      uint8_t gbv = v[0x5010];
      g_guest = 0;
      EXPECT("㉕ 游戏读未登记的 B：不回写（回调次数）", 0, g_touch_n); EXPECT("㉕ 游戏读未登记的 B：读到内存旧值 0", 0, gbv);
      g_gb = ra; s2a_track_reprotect(ra + 0x1000, 0x1000, S2A_TRACK_READ); drain();
      EXPECT("㉕ A 子页 1 改回只跟踪写：页只读", VM_PROT_READ, prot_of(r));
      memset(g_gpu, 0xcd, sizeof g_gpu); s2a_track_reprotect(ra + 0x1000, 0x1000, S2A_TRACK_NONE);
      EXPECT("㉕ 已登记的 A 再被 GPU 改：随即不可读", VM_PROT_NONE, prot_of(r));
      g_touch_n = 0; g_guest = 1;
      uint8_t ga2 = v[0x1010];
      g_guest = 0;
      EXPECT("㉕ 再读 A：先回写（回调次数）", 1, g_touch_n); EXPECT("㉕ 再读 A：读到 GPU 的 0xCD", 0xcd, ga2);
      s2a_track_set_touch(NULL); s2a_track_reprotect(ra, 0x8000, S2A_TRACK_RW); drain(); release_tracked(r, 0x8000); }
    // ㉖ 同一宿主页、不同子页（方案 B：缺页处模拟读）：页 R 子页 1、3 GPU 改过（GPU 侧 0xAB），子页 0、2 没改过（内存 0x22），整页登记定向读时回写。
    //    期望按「只有 GPU 改过的那个子页需要回写」直接定：读子页 2 → 不回写（0 次）、读到内存 0x22、页仍不可读、模拟 1 次；
    //    读子页 1 → 只回写子页 1（1 次）、读到 0xAB、子页 3 仍 GPU 改过、页仍不可读；写子页 2（写走原路径）→ 回写剩下的 GPU 改过子页 3（1 次）、写落地、子页 3 读到 0xAB。
    //    反证（模拟关 = 旧代码）：读子页 2 把子页 1、3 都回写（2 次），这就是 16 KB / 4 KB 的假共享
    for (int emul = 0; emul <= 1; emul++) {
      uint8_t *r = mmap(NULL, 0x4000, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); memset(r, 0x22, 0x4000); uint64_t ra = (uint64_t)(uintptr_t)r;
      vm_address_t al = 0; vm_prot_t cur, max;
      kern_return_t kr = vm_remap(mach_task_self(), &al, 0x4000, 0, VM_FLAGS_ANYWHERE, mach_task_self(), (vm_address_t)ra, FALSE, &cur, &max, VM_INHERIT_NONE);
      EXPECT("㉖ 建可读别名（vm_remap 共享）", KERN_SUCCESS, kr); mprotect((void *)al, 0x4000, PROT_READ);
      g_gb = ra; memset(g_gpu, 0xab, sizeof g_gpu);
      s2a_track_set_readflush(0); s2a_track_set_emul(emul); s2a_track_prot_changed(ra, 0x4000); drain();
      s2a_track_reprotect(ra + 0x1000, 0x1000, S2A_TRACK_NONE); s2a_track_reprotect(ra + 0x3000, 0x1000, S2A_TRACK_NONE);
      s2a_track_mark_readflush(ra, 0x4000);
      EXPECT(emul ? "㉖ 登记后页不可读" : "㉖ 反证：登记后页不可读", VM_PROT_NONE, prot_of(r));
      volatile uint8_t *v = r; g_touch_n = 0; s2a_track_set_touch(ryu_touch); g_alias = emul ? (uint64_t)al : 0; g_alias_of = ra;
      s2a_track_stat st0; s2a_track_stats(&st0); (void)st0;
      g_guest = 1; uint8_t a2 = v[0x2010]; g_guest = 0;
      if (!emul) { EXPECT("㉖ 反证（模拟关）：读没改过的子页 2 也把子页 1、3 回写", 2, g_touch_n); EXPECT("㉖ 反证：读到 0x22", 0x22, a2); }
      else {
        EXPECT("㉖ 读没改过的子页 2：不回写", 0, g_touch_n); EXPECT("㉖ 读子页 2：读到内存 0x22", 0x22, a2);
        EXPECT("㉖ 读子页 2 后：页仍不可读", VM_PROT_NONE, prot_of(r)); EXPECT("㉖ 读子页 2 后：子页 1 仍 GPU 改过", 1, s2a_track_gpu_modified(ra + 0x1000, 8));
        g_touch_n = 0; g_guest = 1; uint8_t a1 = v[0x1010]; g_guest = 0;
        EXPECT("㉖ 读 GPU 改过的子页 1：只回写子页 1", 1, g_touch_n); EXPECT("㉖ 读子页 1：读到 GPU 的 0xAB", 0xab, a1);
        EXPECT("㉖ 读子页 1 后：子页 3 仍 GPU 改过", 1, s2a_track_gpu_modified(ra + 0x3000, 8)); EXPECT("㉖ 读子页 1 后：页仍不可读", VM_PROT_NONE, prot_of(r));
        g_touch_n = 0; g_guest = 1; uint8_t a0 = v[0x0008]; g_guest = 0;
        EXPECT("㉖ 再读没改过的子页 0：不回写", 0, g_touch_n); EXPECT("㉖ 读子页 0：读到 0x22", 0x22, a0);
        // 共享别名、不是拷贝：别名建好后原页被写过（经写跟踪的托管写），模拟读拿到新值
        s2a_track_write(ra + 0x2020, 1); r[0x2020] = 0x5c; s2a_track_reprotect(ra + 0x3000, 0x1000, S2A_TRACK_NONE); drain();
        s2a_track_mark_readflush(ra, 0x4000);
        g_touch_n = 0; g_guest = 1; uint8_t a5 = v[0x2020]; g_guest = 0;
        EXPECT("㉖ 原页写过后模拟读：拿到新值 0x5C（别名共享）", 0x5c, a5);
        g_touch_n = 0; g_guest = 1; v[0x2030] = 0x77; g_guest = 0;
        EXPECT("㉖ 写没改过的子页 2：回写剩下的子页 3（1 次）", 1, g_touch_n); EXPECT("㉖ 写落地", 0x77, r[0x2030]);
        EXPECT("㉖ 写后子页 3 读到 GPU 的 0xAB", 0xab, r[0x3010]);
      }
      g_alias = 0; s2a_track_set_emul(0); s2a_track_set_touch(NULL); s2a_track_reprotect(ra, 0x4000, S2A_TRACK_RW); drain();
      vm_deallocate(mach_task_self(), al, 0x4000); release_tracked(r, 0x4000);
    }
    // ㉗ 部分回写的两种 Ryujinx 行为都要能前进、不读旧值：
    //    ① 句柄连带：子页 1、3 同属一个贴图句柄，读子页 1 时 Ryujinx 把 1、3 都回写并改保护 → 读子页 3 不再回写（0 次）、读到 0xAB、页回到只读（没有 GPU 改过子页了）
    //    ② 无可回写：子页 1 标着 GPU 改过、Ryujinx 那边已回写过（回调什么都不做）→ 读子页 1 回调 1 次后不再缺页（不空转）、页可读
    { uint8_t *r = mmap(NULL, 0x4000, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); memset(r, 0x22, 0x4000); uint64_t ra = (uint64_t)(uintptr_t)r;
      vm_address_t al = 0; vm_prot_t cur, max; vm_remap(mach_task_self(), &al, 0x4000, 0, VM_FLAGS_ANYWHERE, mach_task_self(), (vm_address_t)ra, FALSE, &cur, &max, VM_INHERIT_NONE); mprotect((void *)al, 0x4000, PROT_READ);
      g_gb = ra; memset(g_gpu, 0xab, sizeof g_gpu); s2a_track_set_emul(1); s2a_track_prot_changed(ra, 0x4000); drain();
      s2a_track_reprotect(ra + 0x1000, 0x1000, S2A_TRACK_NONE); s2a_track_reprotect(ra + 0x3000, 0x1000, S2A_TRACK_NONE); s2a_track_mark_readflush(ra, 0x4000);
      volatile uint8_t *v = r; g_alias = (uint64_t)al; g_alias_of = ra; g_grp_also = ra + 0x3000; g_grp_noop = 0; s2a_track_set_touch(ryu_touch_grp);
      g_touch_n = 0; g_guest = 1; uint8_t a1 = v[0x1010]; g_guest = 0;
      EXPECT("㉗① 读子页 1：回调 1 次、读到 0xAB", 1 * 1000 + 0xab, g_touch_n * 1000 + a1);
      g_touch_n = 0; g_guest = 1; uint8_t a3 = v[0x3010]; g_guest = 0;
      EXPECT("㉗① 读连带回写过的子页 3：不再回写", 0, g_touch_n); EXPECT("㉗① 读子页 3：读到 GPU 的 0xAB", 0xab, a3);
      EXPECT("㉗① 页回到只读", VM_PROT_READ, prot_of(r));
      s2a_track_reprotect(ra + 0x1000, 0x1000, S2A_TRACK_NONE); s2a_track_reprotect(ra + 0x3000, 0x1000, S2A_TRACK_NONE); g_grp_noop = 1;
      g_touch_n = 0; g_guest = 1; uint8_t b1 = v[0x1010]; g_guest = 0;
      EXPECT("㉗② 无可回写：回调 1 次后前进（不空转）", 1, g_touch_n); EXPECT("㉗② 读到内存现值 0xAB", 0xab, b1);
      g_alias = 0; g_grp_noop = 0; g_grp_also = 0; s2a_track_set_emul(0); s2a_track_set_touch(NULL); s2a_track_reprotect(ra, 0x4000, S2A_TRACK_RW); drain();
      vm_deallocate(mach_task_self(), al, 0x4000); release_tracked(r, 0x4000); }
    // ㉘ 宿主读不经页保护（贴图回写原样拷目标段）：页子页 1 GPU 改过、登记读时回写 → 页不可读。期望（按「别名共享同一物理页」直接定）：
    //    读出的字节 = 内存现值（子页 0 的 0x33、子页 1 的 0x44）、不缺页（缺页计数不变）、页仍不可读、返回 1（走了别名）；只读页（没登记的另一页）直接拷、返回 0
    { uint8_t *r = mmap(NULL, 0x8000, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); uint64_t ra = (uint64_t)(uintptr_t)r;
      memset(r, 0x33, 0x1000); memset(r + 0x1000, 0x44, 0x3000); memset(r + 0x4000, 0x55, 0x4000);
      s2a_track_set_readflush(0); s2a_track_prot_changed(ra, 0x8000); drain();
      s2a_track_reprotect(ra + 0x1000, 0x1000, S2A_TRACK_NONE); s2a_track_reprotect(ra + 0x4000, 0x4000, S2A_TRACK_READ); s2a_track_mark_readflush(ra, 0x4000);
      EXPECT("㉘ 前提：页不可读", VM_PROT_NONE, prot_of(r));
      uint8_t buf[0x2000]; uint64_t f0 = faults(); int used = s2a_track_read_untracked(ra + 0x800, buf, 0x1000);
      EXPECT("㉘ 走了别名", 1, used); EXPECT("㉘ 不缺页", 0, (long long)(faults() - f0));
      EXPECT("㉘ 子页 0 段读到 0x33", 0x33, buf[0]); EXPECT("㉘ 子页 1 段读到 0x44", 0x44, buf[0xfff]);
      EXPECT("㉘ 读后页仍不可读", VM_PROT_NONE, prot_of(r));
      used = s2a_track_read_untracked(ra + 0x4100, buf, 0x100);
      EXPECT("㉘ 只读页直接拷：返回 0", 0, used); EXPECT("㉘ 只读页读到 0x55", 0x55, buf[0x80]);
      s2a_track_reprotect(ra, 0x8000, S2A_TRACK_RW); drain(); release_tracked(r, 0x8000); }
    // ㉙ 部分回写并发：页里子页 0、3 都 GPU 改过（每轮 GPU 侧值 = 轮号），A 线程读子页 0、B 线程同时读子页 3，200 轮。
    //    期望（按「读到的必须是 GPU 值」直接定）：两线程每轮都读到轮号——A 的部分回写只放开子页 0，B 读子页 3 时页仍不可读、照样先回写
    { uint8_t *r = mmap(NULL, 0x4000, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); memset(r, 0x11, 0x4000); uint64_t ra = (uint64_t)(uintptr_t)r;
      vm_address_t al = 0; vm_prot_t cur, max; vm_remap(mach_task_self(), &al, 0x4000, 0, VM_FLAGS_ANYWHERE, mach_task_self(), (vm_address_t)ra, FALSE, &cur, &max, VM_INHERIT_NONE); mprotect((void *)al, 0x4000, PROT_READ);
      g_gb = ra; s2a_track_set_emul(1); s2a_track_set_readflush(0); s2a_track_prot_changed(ra, 0x4000); drain(); s2a_track_mark_readflush(ra, 0x4000);
      g_part_mem = r; g_alias = (uint64_t)al; g_alias_of = ra; s2a_track_set_touch(ryu_touch_part); s2a_track_set_walias(1); g_part_bad[0] = g_part_bad[1] = 0; g_touch_n = 0;
      pthread_t ta, tb; pthread_create(&ta, NULL, part_reader, (void *)0); pthread_create(&tb, NULL, part_reader, (void *)1);
      for (int rr = 1; rr <= 200; rr++) {
          memset(g_gpu, rr, sizeof g_gpu); s2a_track_reprotect(ra, 0x1000, S2A_TRACK_NONE); s2a_track_reprotect(ra + 0x3000, 0x1000, S2A_TRACK_NONE);
          g_guest = 1; part_bar(); part_bar(); g_guest = 0; }
      pthread_join(ta, NULL); pthread_join(tb, NULL);
      EXPECT("㉙ 部分回写并发：A 读子页 0 读错轮数", 0, g_part_bad[0]); EXPECT("㉙ 部分回写并发：B 同时读子页 3 读错轮数", 0, g_part_bad[1]);
      // 回写次数只能要求下限：A 部分回写子页 0 后把同页其余仍标 GPU 改过的子页设回拦截，若 B 已先回写完子页 3，子页 3 会被再拦一次、B 再回写一次（同值，读数照样对）——
      // 次数依赖两线程交错，不是正确性判据（10-23 曾写成恰好 400，220 遍里撞到 1 次 401）；正确性看上面两项读错轮数
      EXPECT("㉙ 每轮至少两次回写（各回写所碰子页；多出的是交错下的同值重回写）", 1, g_touch_n >= 400);
      g_alias = 0; s2a_track_set_walias(0); s2a_track_set_emul(0); s2a_track_set_touch(NULL); s2a_track_reprotect(ra, 0x4000, S2A_TRACK_RW); drain();
      vm_deallocate(mach_task_self(), al, 0x4000); release_tracked(r, 0x4000); }
    // ㉛ 拦写模拟（docs/研究/拦写模拟.md）：子页 1 由缓冲标 GPU 改过、GPU 只改了 0x10–0x230（字节表）；游戏写子页 1 别处
    //   旧路径（模拟关）：先回写（回调 1 次 = 原版会等的这一下）再写；新路径：不回写、页保持拦截、排空交出恰好写到的字节；Ryujinx 随后回写精确修改区间。
    //   两条路最终内存逐字节相同。另测同值写、真冲突（写到 GPU 改过字节 → 照旧回写）、污染子页、排空中让路、清字节表、并发不丢写
    { static uint8_t fin[2][0x4000]; int touches[2] = {0, 0};
      for (int path = 0; path < 2; path++) {
        // 用没被前面用例用过的地址：污染位永不清（保守），复用过的地址可能带着前面用例非缓冲来源标的 NONE
        uint8_t *r = mmap((void *)(uintptr_t)(0x5800000000ull + (uint64_t)path * 0x100000), 0x4000, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0); uint64_t ra = (uint64_t)(uintptr_t)r;
        memset(r, 0x22, 0x4000);
        vm_address_t al = 0; vm_prot_t cur, max;
        kern_return_t kr = vm_remap(mach_task_self(), &al, 0x4000, 0, VM_FLAGS_ANYWHERE, mach_task_self(), (vm_address_t)ra, FALSE, &cur, &max, VM_INHERIT_NONE);
        if (path) EXPECT("㉛ 建可写别名（vm_remap 共享）", KERN_SUCCESS, kr);
        mprotect((void *)al, 0x4000, PROT_READ | PROT_WRITE);
        g_gb = ra; memcpy(g_gpu, r, 0x4000); for (int i = 0x1010; i < 0x1230; i++) g_gpu[i] = (uint8_t)(i * 7 + 1);   // GPU 只改了这一段
        s2a_track_set_emul_store(path); s2a_track_prot_changed(ra, 0x4000); drain(); s2a_track_drain_done();
        s2a_track_reprotect(ra, 0x4000, S2A_TRACK_READ);
        s2a_track_mod_set(ra + 0x1010, 0x220);
        s2a_track_reprotect(ra + 0x1000, 0x1000, S2A_TRACK_NONE | S2A_TRACK_FROM_BUFFER);
        g_touch_n = 0; s2a_track_set_touch(ryu_touch); g_wal = path ? (uint64_t)al : 0; g_alias_of = ra;
        uint64_t f0 = faults();
        g_guest = 1; *(volatile uint32_t *)(r + 0x1800) = 0xAABBCCDDu; g_guest = 0;
        touches[path] = g_touch_n;
        if (path) {
          EXPECT("㉛① 不碰 GPU 字节的写：不回写", 0, g_touch_n);
          EXPECT("㉛① 写落到内存", 0xAABBCCDDu, *(volatile uint32_t *)(r + 0x1800));
          EXPECT("㉛① 页保持拦截（只读）", VM_PROT_READ, prot_of(r));
          drain(); const s2a_track_precise *q = rec_at(ra + 0x1000);
          EXPECT("㉛① 排空：子页 1 有精确写", 1, q != NULL);
          EXPECT("㉛① 位图恰好 0x800–0x803 四个字节", 1, q && popc(q) == 4 && bit(q, 0x800) && bit(q, 0x803));
          s2a_track_drain_done();
          g_guest = 1; *(volatile uint8_t *)(r + 0x1900) = 0x22; g_guest = 0;   // ② 同值写
          EXPECT("㉛② 同值写：不回写", 0, g_touch_n);
          drain(); q = rec_at(ra + 0x1000);
          EXPECT("㉛② 同值写照样记进位图（0x900 一个字节）", 1, q && popc(q) == 1 && bit(q, 0x900));
          s2a_track_drain_done();
          s2a_track_write_untracked(ra + 0x1010, g_gpu + 0x1010, 0x220, 1);   // Ryujinx 之后回写精确修改区间
          s2a_track_mod_clear(ra + 0x1010, 0x220);
        } else {
          EXPECT("㉛① 反证（旧路径）：先回写 1 次", 1, g_touch_n);
          g_guest = 1; *(volatile uint8_t *)(r + 0x1900) = 0x22; g_guest = 0;
        }
        memcpy(fin[path], r, 0x4000);
        if (path) {
          uint64_t es[12]; s2a_track_es_stats(es); EXPECT("㉛ 计数：模拟 2 次", 2, es[0]); (void)f0;
          printf("    ㉛ 没模拟原因：无担保 %llu 污染 %llu 碰字节 %llu 排空中 %llu 槽满 %llu 越子页 %llu 别名 %llu 解码 %llu\n", es[3], es[4], es[5], es[6], es[7], es[8], es[9], es[10]);
          // ③ 真冲突：重新标 GPU 改过 0x100–0x140，游戏写 0x110 → 不模拟、照旧回写，结果是 CPU 的值
          s2a_track_mod_set(ra + 0x1100, 0x40); for (int i = 0x1100; i < 0x1140; i++) g_gpu[i] = 0x77;
          s2a_track_reprotect(ra + 0x1000, 0x1000, S2A_TRACK_NONE | S2A_TRACK_FROM_BUFFER);   // GPU 又写了这段：缓冲重新标 GPU 改过
          g_touch_n = 0; g_guest = 1; *(volatile uint8_t *)(r + 0x1110) = 0x5e; g_guest = 0;
          EXPECT("㉛③ 写到 GPU 改过的字节：照旧回写（等）", 1, g_touch_n);
          EXPECT("㉛③ 结果是 CPU 的值", 0x5e, *(volatile uint8_t *)(r + 0x1110));
          EXPECT("㉛③ 同段别的字节是 GPU 的值", 0x77, *(volatile uint8_t *)(r + 0x1120));
          // ④ 污染：子页 2 由非缓冲来源标 GPU 改过（不带担保位）→ 不模拟
          s2a_track_reprotect(ra + 0x2000, 0x1000, S2A_TRACK_NONE);
          g_touch_n = 0; g_guest = 1; *(volatile uint32_t *)(r + 0x2800) = 1; g_guest = 0;
          EXPECT("㉛④ 贴图等非缓冲来源标的子页：照旧回写", 1, g_touch_n);
          // ⑤ 排空中让路：子页 3 缓冲标、字节表空；排空后没调 drain_done 时写 → 老路；drain_done 之后 → 模拟
          s2a_track_reprotect(ra + 0x3000, 0x1000, S2A_TRACK_NONE | S2A_TRACK_FROM_BUFFER); drain();
          g_touch_n = 0; g_guest = 1; *(volatile uint32_t *)(r + 0x3800) = 2; g_guest = 0;
          EXPECT("㉛⑤ 排空中（C# 还没处理完）：照旧回写", 1, g_touch_n);
          s2a_track_drain_done(); s2a_track_reprotect(ra + 0x3000, 0x1000, S2A_TRACK_NONE | S2A_TRACK_FROM_BUFFER);
          g_touch_n = 0; g_guest = 1; *(volatile uint32_t *)(r + 0x3810) = 3; g_guest = 0;
          EXPECT("㉛⑤ drain_done 之后：模拟、不回写", 0, g_touch_n);
          drain(); s2a_track_drain_done();
          // ⑥ 清字节表：子页 1 重新缓冲标，0x1100–0x1140 已回写后 mod_clear → 写 0x1104 能模拟
          s2a_track_reprotect(ra + 0x1000, 0x1000, S2A_TRACK_NONE | S2A_TRACK_FROM_BUFFER); s2a_track_mod_clear(ra + 0x1100, 0x40);
          g_touch_n = 0; g_guest = 1; *(volatile uint8_t *)(r + 0x1104) = 0x66; g_guest = 0;
          EXPECT("㉛⑥ 字节表清掉的段：模拟、不回写", 0, g_touch_n);
          // ⑦ 字节表向外取整：标 0x1300 一个字节 → 0x1300–0x133F 整块都算 GPU 改过，写 0x133F 走老路
          s2a_track_mod_set(ra + 0x1300, 1); g_touch_n = 0; g_guest = 1; *(volatile uint8_t *)(r + 0x133F) = 1; g_guest = 0;
          EXPECT("㉛⑦ 字节表 64 字节向外取整：同块别的字节也照旧回写", 1, g_touch_n);
          drain(); s2a_track_drain_done();
          // ⑧ 并发：两条线程各写 2 万次（每次缺页、模拟），主线程同时排空；最后两处都是各自最后写的值、位图不丢、一次都不回写
          //   走老路时的回写照产品只写 GPU 精确修改区间（ryu_touch_exact；字节表此时已清空 = 什么都不写）。原先用整子页拷 g_gpu 的 ryu_touch：
          //   排空中让路超时（门禁机负载下主线程在 drain 与 drain_done 之间被调走 > 200 µs）恰在一条线程写完后发生时，过期副本盖掉它最后写的值
          //   （10-24 test/sysdata 门禁偶发红，真结果 0x2222… = 用例初值）。主线程在一条线程写完后停 500 µs 一次，把这条路变成每次都走
          s2a_track_reprotect(ra + 0x1000, 0x1000, S2A_TRACK_NONE | S2A_TRACK_FROM_BUFFER);
          s2a_track_set_touch(ryu_touch_exact); g_mlo = g_mhi = 0;
          g_es_mem = r; atomic_store(&g_es_go, 0); atomic_store(&g_es_done, 0); g_touch_n = 0;
          uint64_t ew0[12]; s2a_track_es_stats(ew0);
          pthread_t t0, t1; pthread_create(&t0, NULL, es_writer, (void *)0); pthread_create(&t1, NULL, es_writer, (void *)1);
          atomic_store(&g_es_go, 1);
          int seen0 = 0, seen1 = 0, drains = 0, stalled = 0; void *rv;
          while (atomic_load(&g_es_done) < 2 && drains < 2000000) { drain(); const s2a_track_precise *q = rec_at(ra + 0x1000); if (q) { seen0 |= bit(q, 0x400) && bit(q, 0x407); seen1 |= bit(q, 0xC00) && bit(q, 0xC07); }
            if (!stalled && atomic_load(&g_es_done) == 1) { stalled = 1; usleep(500); } s2a_track_drain_done(); drains++; usleep(50); }
          pthread_join(t0, &rv); pthread_join(t1, &rv);
          drain(); { const s2a_track_precise *q = rec_at(ra + 0x1000); if (q) { seen0 |= bit(q, 0x400); seen1 |= bit(q, 0xC00); } } s2a_track_drain_done();
          EXPECT("㉛⑧ 并发：线程 0 最后写的值", 20000ull * 0x0101010101010101ull, *(volatile uint64_t *)(r + 0x1400));
          EXPECT("㉛⑧ 并发：线程 1 最后写的值", 20000ull * 0x0101010101010101ull + 1, *(volatile uint64_t *)(r + 0x1C00));
          EXPECT("㉛⑧ 并发：两处的写都进过位图", 1, seen0 && seen1);
          printf("    ㉛⑧ 并发中走老路（回写）%d 次（排空中让路超时才会走；正确性看上面两项）\n", g_touch_n);
          s2a_track_es_stats(es); printf("    ㉛ 累计模拟 %llu 次，主线程并发排空 %d 次\n", (unsigned long long)es[0], drains);
          printf("    ㉛⑧ 期间没模拟原因增量：无担保 %llu 污染 %llu 碰字节 %llu 排空中 %llu 槽满 %llu 越子页 %llu 别名 %llu 解码 %llu；模拟 %llu 次\n",
                 es[3] - ew0[3], es[4] - ew0[4], es[5] - ew0[5], es[6] - ew0[6], es[7] - ew0[7], es[8] - ew0[8], es[9] - ew0[9], es[10] - ew0[10], es[0] - ew0[0]);
        }
        g_wal = 0; s2a_track_set_touch(NULL); s2a_track_reprotect(ra, 0x4000, S2A_TRACK_RW); drain(); s2a_track_drain_done(); s2a_track_set_emul_store(0);
        vm_deallocate(mach_task_self(), al, 0x4000); munmap(r, 0x4000);
        if (path) printf("    ㉛ 测试页地址 %#llx\n", (unsigned long long)ra);
      }
      EXPECT("㉛ 新旧路径最终内存逐字节相同", 0, memcmp(fin[0], fin[1], 0x4000));
      (void)touches; }
    // ㉜ 时序（总指挥 10-24）：GPU 写 [0x1010, 0x1230) 已提交、没做完 → CPU 写 → GPU 做完 → CPU 读 → 下次 GPU 用。
    //   判据：重叠照样等（回写 1 次）、值对；不重叠不等（新路径回写 0 次）、值对。读也走回写（定向读时回写），回写只写精确修改区间。新旧路径都过，最终内存逐字节相同
    { static uint8_t fin2[2][0x4000]; uint8_t gpu_y = 0;
      for (int path = 0; path < 2; path++) {
        uint8_t *r = mmap((void *)(uintptr_t)(0x5800000000ull + 0x400000ull + (uint64_t)path * 0x100000), 0x4000, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0); uint64_t ra = (uint64_t)(uintptr_t)r;
        memset(r, 0x22, 0x4000);
        vm_address_t al = 0; vm_prot_t cur, max;
        vm_remap(mach_task_self(), &al, 0x4000, 0, VM_FLAGS_ANYWHERE, mach_task_self(), (vm_address_t)ra, FALSE, &cur, &max, VM_INHERIT_NONE); mprotect((void *)al, 0x4000, PROT_READ | PROT_WRITE);
        g_gb = ra; memcpy(g_gpu, r, 0x4000); for (int i = 0x1010; i < 0x1230; i++) g_gpu[i] = (uint8_t)(i * 7 + 1);
        g_mlo = ra + 0x1010; g_mhi = ra + 0x1230;
        s2a_track_set_emul_store(path); s2a_track_set_emul(0); s2a_track_prot_changed(ra, 0x4000); drain(); s2a_track_drain_done();
        s2a_track_reprotect(ra, 0x4000, S2A_TRACK_READ);
        s2a_track_mod_set(ra + 0x1010, 0x220); s2a_track_reprotect(ra + 0x1000, 0x1000, S2A_TRACK_NONE | S2A_TRACK_FROM_BUFFER); s2a_track_mark_readflush(ra, 0x4000);
        s2a_track_set_touch(ryu_touch_exact); g_wal = path ? (uint64_t)al : 0; g_alias_of = ra; const char *pn = path ? "新路径" : "旧路径"; char nm[120];
        // A 重叠：CPU 写 0x1100（GPU 改过的字节）
        g_touch_n = 0; g_guest = 1; *(volatile uint8_t *)(r + 0x1100) = 0x5e; g_guest = 0;
        snprintf(nm, sizeof nm, "㉜A %s 重叠写：照样回写（等）1 次", pn); EXPECT(nm, 1, g_touch_n);
        g_guest = 1; uint8_t x = *(volatile uint8_t *)(r + 0x1100), y = *(volatile uint8_t *)(r + 0x1120); g_guest = 0;
        snprintf(nm, sizeof nm, "㉜A %s CPU 读写过的字节：CPU 的值", pn); EXPECT(nm, 0x5e, x);
        snprintf(nm, sizeof nm, "㉜A %s 读同段没写的字节：GPU 的值", pn); EXPECT(nm, (uint8_t)(0x1120 * 7 + 1), y);
        drain(); s2a_track_drain_done();
        // B 不重叠：GPU 又写了这一段（重新标）；CPU 写 0x1800
        s2a_track_mod_set(ra + 0x1010, 0x220); s2a_track_reprotect(ra + 0x1000, 0x1000, S2A_TRACK_NONE | S2A_TRACK_FROM_BUFFER); s2a_track_mark_readflush(ra, 0x4000);
        for (int i = 0x1010; i < 0x1230; i++) g_gpu[i] = (uint8_t)(i * 11 + 3);
        g_touch_n = 0; g_guest = 1; *(volatile uint32_t *)(r + 0x1800) = 0x01020304u; g_guest = 0;
        snprintf(nm, sizeof nm, "㉜B %s 不重叠写：回写次数", pn); EXPECT(nm, path ? 0 : 1, g_touch_n);
        g_guest = 1; uint32_t yv = *(volatile uint32_t *)(r + 0x1800); g_guest = 0;
        snprintf(nm, sizeof nm, "㉜B %s CPU 读写过的字节：CPU 的值", pn); EXPECT(nm, 0x01020304u, yv);
        g_guest = 1; gpu_y = *(volatile uint8_t *)(r + 0x1050); g_guest = 0;
        snprintf(nm, sizeof nm, "㉜B %s 读 GPU 改过的字节：GPU 的值", pn); EXPECT(nm, (uint8_t)(0x1050 * 11 + 3), gpu_y);
        g_guest = 1; yv = *(volatile uint32_t *)(r + 0x1800); g_guest = 0;
        snprintf(nm, sizeof nm, "㉜B %s 回写之后 CPU 写过的字节仍是 CPU 的值", pn); EXPECT(nm, 0x01020304u, yv);
        if (path) {   // 下次 GPU 用：排空交出的位图恰好是 CPU 写的 4 个字节，按位图「上传」后 GPU 侧是 CPU 的值
          drain(); const s2a_track_precise *q = rec_at(ra + 0x1000);
          EXPECT("㉜B 新路径 排空位图恰好 0x800–0x803", 1, q && popc(q) == 4 && bit(q, 0x800) && bit(q, 0x803));
          if (q) for (int k = 0; k < 0x1000; k++) if (bit(q, (unsigned)k)) g_gpu[0x1000 + k] = r[0x1000 + k];
          EXPECT("㉜B 新路径 上传后 GPU 侧 0x1800 是 CPU 的值", 0x01020304u, *(uint32_t *)(g_gpu + 0x1800));
          s2a_track_drain_done(); }
        else { drain(); s2a_track_drain_done(); }
        memcpy(fin2[path], r, 0x4000);
        g_wal = 0; s2a_track_set_touch(NULL); s2a_track_reprotect(ra, 0x4000, S2A_TRACK_RW); drain(); s2a_track_drain_done(); s2a_track_set_emul_store(0);
        vm_deallocate(mach_task_self(), al, 0x4000); release_tracked(r, 0x4000);
      }
      EXPECT("㉜ 新旧路径最终内存逐字节相同", 0, memcmp(fin2[0], fin2[1], 0x4000)); }
    // ㉝ 字节表「只许多记」：GPU 改过 [0x1010, 0x1230)，Ryujinx 清掉 [0x1008, 0x1108)。只清完全落在区间里的 64 字节块：
    //   0x1000–0x103F 块只被部分清，块里 GPU 改过的 0x1010 仍算 GPU 改过 → 写它走老路；0x1040–0x107F 整块被清 → 写 0x1050 能模拟
    { uint8_t *r = mmap((void *)(uintptr_t)(0x5800000000ull + 0x800000ull), 0x4000, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0); uint64_t ra = (uint64_t)(uintptr_t)r;
      memset(r, 0x22, 0x4000);
      vm_address_t al = 0; vm_prot_t cur, max;
      vm_remap(mach_task_self(), &al, 0x4000, 0, VM_FLAGS_ANYWHERE, mach_task_self(), (vm_address_t)ra, FALSE, &cur, &max, VM_INHERIT_NONE); mprotect((void *)al, 0x4000, PROT_READ | PROT_WRITE);
      g_gb = ra; memcpy(g_gpu, r, 0x4000); g_mlo = ra + 0x1010; g_mhi = ra + 0x1230;
      s2a_track_set_emul_store(1); s2a_track_set_emul(0); s2a_track_prot_changed(ra, 0x4000); drain(); s2a_track_drain_done();
      s2a_track_reprotect(ra, 0x4000, S2A_TRACK_READ);
      s2a_track_mod_set(ra + 0x1010, 0x220); s2a_track_mod_clear(ra + 0x1008, 0x100);
      s2a_track_reprotect(ra + 0x1000, 0x1000, S2A_TRACK_NONE | S2A_TRACK_FROM_BUFFER);
      s2a_track_set_touch(ryu_touch_exact); g_wal = (uint64_t)al; g_alias_of = ra;
      g_touch_n = 0; g_guest = 1; *(volatile uint8_t *)(r + 0x1050) = 1; g_guest = 0;
      EXPECT("㉝ 整块被清的字节（0x1050）：模拟、不回写", 0, g_touch_n);
      g_touch_n = 0; g_guest = 1; *(volatile uint8_t *)(r + 0x1010) = 2; g_guest = 0;
      EXPECT("㉝ 只部分被清的块里 GPU 改过的字节（0x1010）：照旧回写", 1, g_touch_n);
      g_wal = 0; s2a_track_set_touch(NULL); s2a_track_reprotect(ra, 0x4000, S2A_TRACK_RW); drain(); s2a_track_drain_done(); s2a_track_set_emul_store(0);
      vm_deallocate(mach_task_self(), al, 0x4000); release_tracked(r, 0x4000); }
    // ㉞ 同局交替：关段同样的写走老路（回写 1 次），开段模拟（回写 0 次）；关段里字节表照记——关段新标的 GPU 改过字节，到开段写它仍走老路
    { uint8_t *r = mmap((void *)(uintptr_t)(0x5800000000ull + 0xC00000ull), 0x4000, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0); uint64_t ra = (uint64_t)(uintptr_t)r;
      memset(r, 0x22, 0x4000);
      vm_address_t al = 0; vm_prot_t cur, max;
      vm_remap(mach_task_self(), &al, 0x4000, 0, VM_FLAGS_ANYWHERE, mach_task_self(), (vm_address_t)ra, FALSE, &cur, &max, VM_INHERIT_NONE); mprotect((void *)al, 0x4000, PROT_READ | PROT_WRITE);
      g_gb = ra; memcpy(g_gpu, r, 0x4000); g_mlo = ra + 0x1010; g_mhi = ra + 0x1230;
      s2a_track_set_emul_store(1); s2a_track_set_emul(0); s2a_track_prot_changed(ra, 0x4000); drain(); s2a_track_drain_done();
      s2a_track_reprotect(ra, 0x4000, S2A_TRACK_READ); s2a_track_set_touch(ryu_touch_exact); g_wal = (uint64_t)al; g_alias_of = ra;
      g_test_alt = 0;
      s2a_track_mod_set(ra + 0x1010, 0x220); s2a_track_reprotect(ra + 0x1000, 0x1000, S2A_TRACK_NONE | S2A_TRACK_FROM_BUFFER);
      s2a_track_mod_set(ra + 0x1600, 0x10);   // 关段里新标的 GPU 改过字节
      g_touch_n = 0; g_guest = 1; *(volatile uint32_t *)(r + 0x1800) = 7; g_guest = 0;
      EXPECT("㉞ 关段：不碰 GPU 字节的写也走老路（回写 1 次）", 1, g_touch_n);
      drain(); s2a_track_drain_done();   // 老路回写拍下的待比对快照先落地（本测试在信号里直接调回写回调；产品里回写在正常上下文，读不可读页会正常缺页）
      g_test_alt = 1; s2a_track_reprotect(ra + 0x1000, 0x1000, S2A_TRACK_NONE | S2A_TRACK_FROM_BUFFER);
      g_touch_n = 0; g_guest = 1; *(volatile uint32_t *)(r + 0x1900) = 8; g_guest = 0;
      EXPECT("㉞ 开段：同类写模拟（回写 0 次）", 0, g_touch_n);
      g_touch_n = 0; g_guest = 1; *(volatile uint8_t *)(r + 0x1604) = 9; g_guest = 0;
      EXPECT("㉞ 开段：关段里新标的 GPU 改过字节照旧回写", 1, g_touch_n);
      g_test_alt = -1; g_wal = 0; s2a_track_set_touch(NULL); s2a_track_reprotect(ra, 0x4000, S2A_TRACK_RW); drain(); s2a_track_drain_done(); s2a_track_set_emul_store(0);
      vm_deallocate(mach_task_self(), al, 0x4000); munmap(r, 0x4000); }
    // ㊲ 精确快照读（排空消费者，审计 #806 第 5 条）：客人把已建叶子的页收成不可访问（lastp 0xfe）之后再拷——
    //    必须经别名拷到内容、不缺页、不改保护。修前苹果 copy_precise 转 read_untracked，只认 lastp == PROT_NONE 走别名，0xfe 直接读 → 缺页交回（子进程退出 4）
    { uint8_t *r = mmap(NULL, 0x4000, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); memset(r, 0x6c, 0x4000); uint64_t rb = (uint64_t)(uintptr_t)r;
      s2a_track_prot_changed(rb, 0x4000); drain();
      s2a_track_reprotect(rb, 0x4000, S2A_TRACK_READ); s2a_track_reprotect(rb, 0x4000, S2A_TRACK_RW); drain();   // 这页已有叶子、本模块设过保护
      EXPECT("㊲ 前提：客人收成不可访问", 0, s2a_track_set_guest_protection(rb, 0x4000, PROT_NONE));
      fflush(stdout); pid_t pid = fork();
      if (pid == 0) { uint8_t got[0x40] = {0}; s2a_track_copy_precise(rb + 0x1010, got, sizeof got); int ok = 1; for (unsigned k = 0; k < sizeof got; k++) ok &= got[k] == 0x6c;
                      _exit(!ok ? 3 : prot_of(r) != 0 ? 5 : 0); }   // 在子进程里拷（修前缺页会带走整个单测），内容与保护都在子进程里核
      int st = 0; waitpid(pid, &st, 0);
      EXPECT("㊲ 不可访问（0xfe）页精确快照：子进程退出码（0 = 拷到内容且页仍不可访问；3 内容错 / 4 缺页 / 5 保护被改）", 0, WIFEXITED(st) ? WEXITSTATUS(st) : 128 + WTERMSIG(st));
      s2a_track_set_guest_protection(rb, 0x4000, PROT_READ | PROT_WRITE); s2a_track_prot_changed(rb, 0x4000); drain(); munmap(r, 0x4000); }
    t36();
    t37();
    t38();
    t39();
    t40();
    t41();
    t30();
    printf("%s：%d 项，失败 %d\n", "t_track", count, fail);
    return fail != 0;
}
