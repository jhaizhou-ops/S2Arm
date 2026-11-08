// 诊断（原生层线 10-23 暗黑3 读档闪崩确定性复现，只在 Mac 宿主生效，iOS 上空函数；缺省关）：
//   S2A_DIAG_DELAY=<模块>+0x<偏移>:<毫秒>[:<次数>][,<下一点>…] —— 起局装载后把这些游戏指令换成 brk，执行到时在 SIGTRAP 里先睡 <毫秒>（前 <次数> 次，缺省 3；
//   毫秒 0 = 只计数），再模拟原指令、继续。每点前 10 次命中打一行（时刻、线程、该点累计次数）。
//   只认四类原指令：LDP Wt1, Wt2 / Xt1, Xt2, [Xn, #imm]（32 / 64 位，带符号偏移，不回写）、BL、B（相对跳转）、BLR Xn（寄存器间接调用）；别的编码不装（打一行说明）。
//   用途：把游戏「登记 → 使用」之间的空窗人为拉长，并在清理例程的删除调用点计数，看清理是否落进空窗；同一钩子在调度对齐版上再跑一次。
//   S2A_DIAG_STAMP=<模块>+0x<偏移>,<模块>+0x<偏移>,…（2–6 点，同样只认 LDP / BL / B / BLR）：量空窗。按线程在各点打时间戳，
//     第 1 点开窗、最后 1 点收窗；每走完一次记墙钟总长、本线程 CPU 时长（墙钟 ≫ CPU = 被切走 / 阻塞；CPU 大 = 真在执行，如缺页 / 写跟踪）
//     与各分段，按量级计数，留最长 5 次；每 500 次和每出新最长时打一行。brk 陷入本身每点约几 µs，读数含这部分。
//   S2A_DIAG_DUMP=<模块>+0x<偏移>[:x<寄存器号（31 = sp）>[+0x<加数>]:<字节>][,…]（同样只认 LDP / BL / B / BLR）：执行到时打全部寄存器，给了寄存器就再按十六进制
//     打它指向的内存（经 vm_read_overwrite 读，指针是乱值也不崩）；每点前 10 次。用途：看游戏某个调用的入参 / 某张表的内容
//   S2A_DIAG_ALLOC=<模块>+0x<偏移>:x<指针>:x<大小>:x<分配器>:<lr|fp8>[,…] 与 S2A_DIAG_FREE=<模块>+0x<偏移>:x<指针>:x<分配器>:<lr|fp8>[,…]（同样只认 LDP / BL / B / BLR）：
//     游戏自己的分配器记账。分配点执行到时按「指针 → 大小、分配器、调用点」记进在用表，释放点删掉；调用点 lr = 当时的 x30、fp8 = [fp + 8]（已压栈的返回地址）。
//     每 20 秒和收局 / 崩溃时按「分配器 + 调用点」汇总在用块数与字节（前 15），外加每个分配器的分配 / 释放次数——看谁只拿不还
//     （11-02 网球 Aces：游戏分配器给不出 512 字节后自断言 main+0x62aac）
#include "native.h"
#include <TargetConditionals.h>
#if TARGET_OS_IPHONE
void s2a_diag_brk_arm(void) {}
int s2a_diag_brk(void *ctx) { (void)ctx; return 0; }
void s2a_diag_stamp_report(void) {}
#else
#include <signal.h>
#include <errno.h>
#include <sys/mman.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <libkern/OSCacheControl.h>
#include <sys/ucontext.h>
#include <mach/mach_time.h>
#include <stdatomic.h>
#include <pthread.h>
#define DIAG_BRK (0xD4200000u | (0x7DD1u << 5))   // brk #0x7DD1（避开 macOS 截走的 0xB000–0xBFFF）
#define NPT 8
static int g_nst; static mach_timebase_info_data_t g_tb;   // 打点（S2A_DIAG_STAMP）：点数、时基
static struct { uint32_t *at, orig; long ms; int left; _Atomic int hits; int st, dump, dreg, dlen; unsigned dadd; char name[48]; int at_kind, a_ptr, a_size, a_owner, a_fp8; } g_pt[NPT]; static int g_npt;   // at_kind：1 分配点、2 释放点（S2A_DIAG_ALLOC / FREE）   // st：打点序号（1 起；0 = 延时点）；dump：打寄存器点
static int arm_one(const char *e, int st, int dump) {
    char mod[16] = {0}; unsigned long long off = 0; long ms = 0; int cnt = 3, dreg = -1, dlen = 0; unsigned dadd = 0;
    const char *plus = strchr(e, '+'); if (!plus || plus - e >= (long)sizeof mod) return -1;
    memcpy(mod, e, (size_t)(plus - e));
    if (dump) { if (sscanf(plus + 1, "0x%llx:x%d+0x%x:%d", &off, &dreg, &dadd, &dlen) < 4) { dadd = 0; if (sscanf(plus + 1, "0x%llx:x%d:%d", &off, &dreg, &dlen) < 1) return -1; } if (dreg < 0 || dreg > 31 || dlen <= 0) dreg = -1, dlen = 0; if (dlen > 4096) dlen = 4096; }
    else if (sscanf(plus + 1, "0x%llx:%ld:%d", &off, &ms, &cnt) < (st ? 1 : 2)) return -1;
    if (st || dump) ms = 0;
    module_t *m = NULL; for (int i = 0; i < g_nmod; i++) if (!strcmp(g_mod[i].name, mod)) m = &g_mod[i];
    if (!m || off + 4 > m->size || g_npt >= NPT) { LOG("【红】S2A_DIAG_DELAY：没有模块 %s / 偏移越界 / 点太多", mod); return 0; }
    uint32_t *p = (uint32_t *)(m->base + off), w = *p;
    // LDP 32 位 0x294… / 64 位 0xA94…（64 位：分配函数返回前恢复寄存器的 ldp x20, x19, [sp, #…] 常是唯一能挂在「已拿到指针」之后的点）
    // BLR Xn：虚调用点（激战前锋分配器失败分支 blr 进「打统计 + 终止」，那一刻 x1 还是要的大小、x30 还是调用者）
    int ldp = (w & 0x7FC00000u) == 0x29400000u, bl = (w >> 26) == 0x25 || (w >> 26) == 0x05 || (w & 0xFFFFFC1Fu) == 0xD63F0000u;   // BL / B / BLR
    if (!ldp && !bl) { LOG("【红】S2A_DIAG_DELAY：%s+0x%llx 的指令 %08x 不是 LDP（带符号偏移）也不是 BL / B / BLR，不装", mod, off, w); return 0; }
    uintptr_t pg = (uintptr_t)p & ~(uintptr_t)0x3FFF;
    // 代码页是只读文件映射（最大权限无写，mprotect 报 EACCES）：VM_PROT_COPY 给这一页建私有可写副本，写完改回可读可执行
    kern_return_t kr = vm_protect(mach_task_self(), (vm_address_t)pg, 0x4000, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) { LOG("【红】S2A_DIAG_DELAY：vm_protect 写（COPY）失败 kr %d", kr); return 0; }
    int k = g_npt++; g_pt[k].orig = w; g_pt[k].at = p; g_pt[k].ms = ms; g_pt[k].left = ms > 0 ? cnt : 0; g_pt[k].st = st; g_pt[k].dump = dump; g_pt[k].dreg = dreg; g_pt[k].dlen = dlen; g_pt[k].dadd = dadd;
    snprintf(g_pt[k].name, sizeof g_pt[k].name, "%s+0x%llx", mod, off);
    *p = DIAG_BRK;
    kr = vm_protect(mach_task_self(), (vm_address_t)pg, 0x4000, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
    if (kr != KERN_SUCCESS) LOG("【红】S2A_DIAG_DELAY：改回可执行失败 kr %d", kr);
    sys_icache_invalidate(p, 4);
    LOG("诊断钩子：%s（原指令 %08x，%s）%s", g_pt[k].name, w, ldp ? "LDP" : (w >> 26) == 0x25 ? "BL" : (w >> 26) == 0x05 ? "B" : "BLR", dump ? "打寄存器" : st ? "打点" : ms > 0 ? "执行到时睡" : "只计数");
    if (ms > 0) LOG("诊断延时钩子：%s 前 %d 次各睡 %ld ms", g_pt[k].name, cnt, ms);
    return 0;
}
// 分配记账点：先按普通「只计数」点装上（arm_one 认 LDP / BL / B），再记下各寄存器
static void arm_alloc(char *s, int kind) {
    char *c = strchr(s, ':'); if (!c) { LOG("【红】S2A_DIAG_%s 格式不对：%s", kind == 1 ? "ALLOC" : "FREE", s); return; }
    *c++ = 0; int n0 = g_npt; char pt[64]; snprintf(pt, sizeof pt, "%s:0:0", s);
    if (arm_one(pt, 0, 0) < 0 || g_npt == n0) { LOG("【红】S2A_DIAG_%s 没装上：%s", kind == 1 ? "ALLOC" : "FREE", s); return; }
    int k = n0, p = -1, sz = -1, o = -1; char how[8] = "";
    int got = kind == 1 ? sscanf(c, "x%d:x%d:x%d:%7s", &p, &sz, &o, how) : sscanf(c, "x%d:x%d:%7s", &p, &o, how);
    if (got != (kind == 1 ? 4 : 3) || p < 0 || p > 28 || o < 0 || o > 28 || (kind == 1 && (sz < 0 || sz > 28)) || (strcmp(how, "lr") && strcmp(how, "fp8"))) {
        g_pt[k].at_kind = 0; LOG("【红】S2A_DIAG_%s 寄存器写法不对：%s（例 x19:x20:x21:fp8）", kind == 1 ? "ALLOC" : "FREE", c); return; }
    g_pt[k].at_kind = kind; g_pt[k].a_ptr = p; g_pt[k].a_size = sz; g_pt[k].a_owner = o; g_pt[k].a_fp8 = !strcmp(how, "fp8");
    LOG("诊断分配记账：%s 是%s点（指针 x%d%s、分配器 x%d、调用点 %s）", g_pt[k].name, kind == 1 ? "分配" : "释放", p, kind == 1 ? (snprintf(pt, sizeof pt, "、大小 x%d", sz), pt) : "", o, how);
}
void s2a_diag_brk_arm(void) {
    const char *e = getenv("S2A_DIAG_DELAY");
    char buf[512];
    if (e && *e) { strlcpy(buf, e, sizeof buf);
        for (char *s = buf, *t; s && *s; s = t) { t = strchr(s, ','); if (t) *t++ = 0; if (arm_one(s, 0, 0) < 0) LOG("【红】S2A_DIAG_DELAY 格式不对：%s", s); } }
    e = getenv("S2A_DIAG_STAMP");
    if (e && *e) { strlcpy(buf, e, sizeof buf); int st = 0;
        for (char *s = buf, *t; s && *s; s = t) { t = strchr(s, ','); if (t) *t++ = 0; if (arm_one(s, ++st, 0) < 0) LOG("【红】S2A_DIAG_STAMP 格式不对：%s", s); }
        g_nst = st; mach_timebase_info(&g_tb); LOG("诊断打点：%d 点，第 1 点开窗、第 %d 点收窗", st, st); }
    e = getenv("S2A_DIAG_DUMP");
    if (e && *e) { strlcpy(buf, e, sizeof buf);
        for (char *s = buf, *t; s && *s; s = t) { t = strchr(s, ','); if (t) *t++ = 0; if (arm_one(s, 0, 1) < 0) LOG("【红】S2A_DIAG_DUMP 格式不对：%s", s); } }
    // 分配 / 释放点可各给多个（逗号分隔）：同一分配器常有几个入口（普通 / 对齐分配、加锁 / 不加锁两条返回路径）
    e = getenv("S2A_DIAG_ALLOC"); if (e && *e) { strlcpy(buf, e, sizeof buf); for (char *s = buf, *t; s && *s; s = t) { t = strchr(s, ','); if (t) *t++ = 0; arm_alloc(s, 1); } }
    e = getenv("S2A_DIAG_FREE"); if (e && *e) { strlcpy(buf, e, sizeof buf); for (char *s = buf, *t; s && *s; s = t) { t = strchr(s, ','); if (t) *t++ = 0; arm_alloc(s, 2); } }
}
// 打寄存器点（S2A_DIAG_DUMP）：全部寄存器 + 可选一段内存（vm_read_overwrite：读不了就写明，不崩）
static void dump_hit(int k, int h, const _STRUCT_ARM_THREAD_STATE64 *ss) {
    char b[1024]; int n = 0;
    for (int i = 0; i < 29; i++) n += snprintf(b + n, sizeof b - (size_t)n, "%sx%d %llx", i ? " " : "", i, (unsigned long long)ss->__x[i]);
    LOG("诊断打寄存器：%s 第 %d 次（线程 %llu）%s fp %llx lr %llx sp %llx", g_pt[k].name, h, (unsigned long long)pthread_mach_thread_np(pthread_self()), b,
        (unsigned long long)ss->__fp, (unsigned long long)ss->__lr, (unsigned long long)__darwin_arm_thread_state64_get_sp(*ss));
    if (g_pt[k].dreg < 0) return;
    // x29 / x30 在 __fp / __lr（__x 只有 29 格）；x31 这里当 sp（看包装层压栈的返回地址）
    int r = g_pt[k].dreg; uint64_t a = (r < 29 ? ss->__x[r] : r == 29 ? ss->__fp : r == 30 ? ss->__lr : __darwin_arm_thread_state64_get_sp(*ss)) + g_pt[k].dadd; uint8_t mem[4096]; mach_vm_size_t got = 0;
    if (mach_vm_read_overwrite(mach_task_self(), a, (mach_vm_size_t)g_pt[k].dlen, (mach_vm_address_t)(uintptr_t)mem, &got) != KERN_SUCCESS) { LOG("诊断打寄存器：[x%d+%#x = %llx] 读不了", g_pt[k].dreg, g_pt[k].dadd, (unsigned long long)a); return; }
    for (mach_vm_size_t o = 0; o < got; o += 32) {
        n = 0; for (mach_vm_size_t j = o; j < o + 32 && j < got; j += 8) { uint64_t v = 0; memcpy(&v, mem + j, got - j < 8 ? got - j : 8); n += snprintf(b + n, sizeof b - (size_t)n, " %016llx", (unsigned long long)v); }
        LOG("诊断打寄存器：[x%d+%#llx]%s", g_pt[k].dreg, (unsigned long long)(g_pt[k].dadd + o), b);
    }
}
// ---------- 打点（S2A_DIAG_STAMP）----------
#define NSLOT 128
static struct { _Atomic(pthread_t) who; uint64_t t[8], cpu0, svc0, gsv0, tn0, tns0; int seen; } g_ts[NSLOT];   // 每线程一格（按 pthread_self 认领，不释放）
static _Atomic uint64_t g_win_n, g_win_buck[7];   // <1µs <10µs <100µs <1ms <10ms <100ms ≥100ms
static struct { uint64_t wall, cpu, seg[8], nsvc, gsv, tn, tns; int nseg, seen, last_svc, glast; } g_top[5]; static pthread_mutex_t g_top_mu = PTHREAD_MUTEX_INITIALIZER;
static uint64_t ns_of(uint64_t t) { return t * g_tb.numer / g_tb.denom; }
static uint64_t thread_cpu_ns(void) {
    thread_basic_info_data_t bi; mach_msg_type_number_t n = THREAD_BASIC_INFO_COUNT; mach_port_t me = mach_thread_self();
    kern_return_t kr = thread_info(me, THREAD_BASIC_INFO, (thread_info_t)&bi, &n); mach_port_deallocate(mach_task_self(), me);
    if (kr != KERN_SUCCESS) return 0;
    return ((uint64_t)bi.user_time.seconds + bi.system_time.seconds) * 1000000000ull + ((uint64_t)bi.user_time.microseconds + bi.system_time.microseconds) * 1000ull;
}
static int slot_of(void) {
    pthread_t me = pthread_self();
    for (int i = 0; i < NSLOT; i++) { pthread_t w = atomic_load(&g_ts[i].who); if (w == me) return i; if (!w) { pthread_t z = 0; if (atomic_compare_exchange_strong(&g_ts[i].who, &z, me)) return i; if (z == me) return i; } }
    return -1;
}
static const char *buck_name[7] = {"<1µs", "<10µs", "<100µs", "<1ms", "<10ms", "<100ms", "≥100ms"};
static void stamp_report(const char *why) {
    char b[400]; size_t l = 0;
    for (int i = 0; i < 7; i++) l += (size_t)snprintf(b + l, sizeof b - l, "%s%s %llu", i ? "、" : "", buck_name[i], (unsigned long long)atomic_load(&g_win_buck[i]));
    LOG("诊断打点（%s）：空窗走完 %llu 次，分布 %s", why, (unsigned long long)atomic_load(&g_win_n), b);
    if (pthread_mutex_trylock(&g_top_mu)) { LOG("诊断打点：最长表正被别的线程写，这次不打"); return; }   // 崩溃处理里也调：不能等锁
    for (int i = 0; i < 5 && g_top[i].wall; i++) { char sg[200]; size_t q = 0;
        for (int k = 0; k < g_top[i].nseg; k++) q += (size_t)snprintf(sg + q, sizeof sg - q, "%s%.1f", k ? " / " : "", g_top[i].seg[k] / 1000.0);
        char pts[40]; size_t r = 0; for (int k = 1; k <= g_nst; k++) if (g_top[i].seen & (1 << k)) r += (size_t)snprintf(pts + r, sizeof pts - r, "%s%d", r ? "→" : "", k);
        LOG("诊断打点 最长第 %d：墙钟 %.1f µs、本线程 CPU %.1f µs；经过点 %s；分段（µs）%s；窗内系统调用 全部 %llu 次（最近 %#x）、其中线程类 %llu 次（最近 %#x）；写跟踪改道回写 %llu 次共 %.1f µs", i + 1, g_top[i].wall / 1000.0, g_top[i].cpu / 1000.0, pts, sg, (unsigned long long)g_top[i].gsv, g_top[i].glast, (unsigned long long)g_top[i].nsvc, g_top[i].last_svc, (unsigned long long)g_top[i].tn, g_top[i].tns / 1000.0); }
    pthread_mutex_unlock(&g_top_mu);
}
static void ledger_report(const char *why);
// 收局 / 崩溃：延时 / 计数点（S2A_DIAG_DELAY，毫秒 0 = 只计数）打累计命中次数——命中行只打前 10 次，补丁局要读「重试块走了几次」（11-04 假面骑士 [code] 补丁 main+0x8ec334）
void s2a_diag_stamp_report(void) {
    if (g_nst) stamp_report("收局");
    int any = 0; for (int i = 0; i < g_npt; i++) { any |= g_pt[i].at_kind; if (!g_pt[i].st && !g_pt[i].dump && !g_pt[i].at_kind) LOG("诊断延时钩子 收局 / 崩溃：%s 共命中 %d 次", g_pt[i].name, atomic_load(&g_pt[i].hits)); }
    if (any) ledger_report("收局 / 崩溃");
}
static void stamp_hit(int st) {
    int s = slot_of(); if (s < 0) return;
    uint64_t now = mach_absolute_time();
    int s2a_thread_svc_stat(uint64_t *n); uint64_t s2a_gate_svc_stat(int *last), s2a_touch_stat(uint64_t *mach); int gl;
    if (st == 1) { g_ts[s].seen = 1 | 2; g_ts[s].t[1] = now; g_ts[s].cpu0 = thread_cpu_ns(); s2a_thread_svc_stat(&g_ts[s].svc0); g_ts[s].gsv0 = s2a_gate_svc_stat(&gl); g_ts[s].tn0 = s2a_touch_stat(&g_ts[s].tns0); return; }
    if (!(g_ts[s].seen & 1)) return;   // 没开窗就到了中间点 / 收窗点：不算
    g_ts[s].seen |= 1 << st; g_ts[s].t[st] = now;
    if (st != g_nst) return;
    uint64_t wall = ns_of(now - g_ts[s].t[1]), cpu = thread_cpu_ns() - g_ts[s].cpu0, nsv, tns; int lsv = s2a_thread_svc_stat(&nsv); uint64_t gsv = s2a_gate_svc_stat(&gl), tn = s2a_touch_stat(&tns);
    int bk = wall < 1000 ? 0 : wall < 10000 ? 1 : wall < 100000 ? 2 : wall < 1000000 ? 3 : wall < 10000000 ? 4 : wall < 100000000 ? 5 : 6;
    atomic_fetch_add(&g_win_buck[bk], 1); uint64_t n = atomic_fetch_add(&g_win_n, 1) + 1;
    int newtop = 0;
    pthread_mutex_lock(&g_top_mu);
    int pos = 5; for (int i = 0; i < 5; i++) if (wall > g_top[i].wall) { pos = i; break; }
    if (pos < 5) { for (int i = 4; i > pos; i--) g_top[i] = g_top[i - 1];
        g_top[pos].wall = wall; g_top[pos].cpu = cpu; g_top[pos].nseg = 0; g_top[pos].seen = g_ts[s].seen; g_top[pos].nsvc = nsv - g_ts[s].svc0; g_top[pos].last_svc = lsv; g_top[pos].gsv = gsv - g_ts[s].gsv0; g_top[pos].glast = gl; g_top[pos].tn = tn - g_ts[s].tn0; g_top[pos].tns = ns_of(tns - g_ts[s].tns0); uint64_t prev = g_ts[s].t[1];
        for (int k = 2; k <= g_nst; k++) if (g_ts[s].seen & (1 << k)) { g_top[pos].seg[g_top[pos].nseg++] = ns_of(g_ts[s].t[k] - prev); prev = g_ts[s].t[k]; }
        newtop = pos == 0; }
    pthread_mutex_unlock(&g_top_mu);
    g_ts[s].seen = 0;
    if (newtop || n % 500 == 0) stamp_report(newtop ? "新最长" : "每 500 次");
}

// ---------- 分配记账（S2A_DIAG_ALLOC / FREE）----------
#define LSZ (1u << 18)   // 在用表槽数（开放寻址，指针为键；满了记「表满」不再记新块）
static struct { uint64_t ptr, size, owner, caller; } g_live[LSZ];
static atomic_flag g_lk = ATOMIC_FLAG_INIT;
static uint64_t g_nalloc, g_nfree, g_free_unknown, g_full, g_rep_t;
static void lk(void) { while (atomic_flag_test_and_set_explicit(&g_lk, memory_order_acquire)) ; }
static void ulk(void) { atomic_flag_clear_explicit(&g_lk, memory_order_release); }
static unsigned slot_ptr(uint64_t p) { return (unsigned)((p >> 4) * 0x9E3779B97F4A7C15ull >> 46) & (LSZ - 1); }
static void ledger_add(uint64_t p, uint64_t sz, uint64_t o, uint64_t c) {
    if (!p) return;
    for (unsigned i = slot_ptr(p), n = 0; n < LSZ; i = (i + 1) & (LSZ - 1), n++)
        if (!g_live[i].ptr || g_live[i].ptr == p) { g_live[i].ptr = p; g_live[i].size = sz; g_live[i].owner = o; g_live[i].caller = c; return; }
    g_full++;
}
static int ledger_del(uint64_t p) {   // 线性探测删除：后移补洞，保持探测链连续
    unsigned i = slot_ptr(p), n = 0;
    for (; n < LSZ && g_live[i].ptr != p; i = (i + 1) & (LSZ - 1), n++) if (!g_live[i].ptr) return 0;
    if (n == LSZ) return 0;
    for (unsigned j = (i + 1) & (LSZ - 1);; j = (j + 1) & (LSZ - 1)) {
        if (!g_live[j].ptr) break;
        unsigned h = slot_ptr(g_live[j].ptr);
        if ((j > i && (h <= i || h > j)) || (j < i && h <= i && h > j)) { g_live[i] = g_live[j]; i = j; }
    }
    g_live[i].ptr = 0; return 1;
}
static void where(uint64_t a, char *b, size_t n) {   // 地址 → 「模块+偏移」（游戏模块外的写原地址）
    for (int i = 0; i < g_nmod; i++) if (a >= (uint64_t)(uintptr_t)g_mod[i].base && a < (uint64_t)(uintptr_t)g_mod[i].base + g_mod[i].size) {
        snprintf(b, n, "%.16s+%#llx", g_mod[i].name, (unsigned long long)(a - (uint64_t)(uintptr_t)g_mod[i].base)); return; }
    snprintf(b, n, "%#llx", (unsigned long long)a);
}
static void ledger_report(const char *why) {   // 崩溃处理里也调：不能死等锁
    // 先等约 50 ms；还拿不到 = 持锁线程停在崩溃现场（崩溃处理会挂起其余线程，激战前锋第四局就这样一行没打）→ 不加锁照读：
    //   表只增删槽位、读最多读到一个半写的槽，诊断读数够用，比整份汇总丢掉强。没拿到锁也就不释放
    int held = 0;
    for (int i = 0; i < 50000 && !(held = !atomic_flag_test_and_set_explicit(&g_lk, memory_order_acquire)); i++) usleep(1);
    if (!held) LOG("诊断分配记账（%s）：表的锁约 50 ms 没放（持锁线程停在现场），不加锁照读", why);
    static struct { uint64_t owner, caller, n, bytes; } agg[256]; int na = 0; uint64_t tot = 0, totb = 0;
    for (unsigned i = 0; i < LSZ; i++) { if (!g_live[i].ptr) continue; tot++; totb += g_live[i].size;
        int k = 0; for (; k < na && !(agg[k].owner == g_live[i].owner && agg[k].caller == g_live[i].caller); k++) ;
        if (k == na && na < 256) { agg[na].owner = g_live[i].owner; agg[na].caller = g_live[i].caller; agg[na].n = agg[na].bytes = 0; na++; }
        if (k < na) { agg[k].n++; agg[k].bytes += g_live[i].size; } }
    LOG("诊断分配记账（%s）：分配 %llu、释放 %llu（其中不在表里的 %llu）、在用 %llu 块 %.1f KB、表满丢 %llu；按分配器 + 调用点在用前 15：", why,
        (unsigned long long)g_nalloc, (unsigned long long)g_nfree, (unsigned long long)g_free_unknown, (unsigned long long)tot, totb / 1024.0, (unsigned long long)g_full);
    for (int r = 0; r < 15 && r < na; r++) { int b = r; for (int k = r + 1; k < na; k++) if (agg[k].bytes > agg[b].bytes) b = k;
        if (b != r) { __typeof__(agg[0]) t = agg[r]; agg[r] = agg[b]; agg[b] = t; }
        char cw[96]; where(agg[r].caller, cw, sizeof cw);
        LOG("诊断分配记账：  分配器 %llx 调用点 %s：%llu 块 %.1f KB", (unsigned long long)agg[r].owner, cw, (unsigned long long)agg[r].n, agg[r].bytes / 1024.0); }
    if (held) ulk();
}
static void ledger_hit(int k, const _STRUCT_ARM_THREAD_STATE64 *ss) {
    uint64_t c = ss->__lr;
    if (g_pt[k].a_fp8) { mach_vm_size_t got = 0; if (mach_vm_read_overwrite(mach_task_self(), ss->__fp + 8, 8, (mach_vm_address_t)(uintptr_t)&c, &got) != KERN_SUCCESS) c = 0; }
    uint64_t p = ss->__x[g_pt[k].a_ptr], o = ss->__x[g_pt[k].a_owner];
    lk();
    if (g_pt[k].at_kind == 1) { g_nalloc++; ledger_add(p, ss->__x[g_pt[k].a_size], o, c); }
    else { g_nfree++; if (p && !ledger_del(p)) g_free_unknown++; }
    ulk();
    uint64_t now = mach_absolute_time(); if (!g_tb.denom) mach_timebase_info(&g_tb);
    if (ns_of(now - g_rep_t) >= 20000000000ull) { g_rep_t = now; ledger_report("每 20 秒"); }
}

int s2a_diag_brk(void *ctx) {   // SIGTRAP 里调：是本钩子的 brk 就（睡 +）模拟原指令，返回 1
    if (!g_npt) return 0;
    ucontext_t *uc = ctx; _STRUCT_ARM_THREAD_STATE64 *ss = &uc->uc_mcontext->__ss;
    uint32_t *pc = (uint32_t *)(uintptr_t)__darwin_arm_thread_state64_get_pc(*ss);
    int k = -1; for (int i = 0; i < g_npt; i++) if (g_pt[i].at == pc) k = i;
    if (k < 0) return 0;
    int h = ++g_pt[k].hits;
    if (h <= 10 && !g_pt[k].st && !g_pt[k].dump && !g_pt[k].at_kind) { struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts); LOG("诊断延时钩子命中：%s 第 %d 次（%ld.%03ld，线程 %llu）", g_pt[k].name, h, (long)ts.tv_sec % 1000, ts.tv_nsec / 1000000, (unsigned long long)pthread_mach_thread_np(pthread_self())); }
    if (g_pt[k].st) stamp_hit(g_pt[k].st);
    if (g_pt[k].at_kind) ledger_hit(k, ss);
    if (g_pt[k].dump && h <= 10) dump_hit(k, h, ss);
    if (g_pt[k].left > 0) { g_pt[k].left--; struct timespec ts = {g_pt[k].ms / 1000, (g_pt[k].ms % 1000) * 1000000L}; nanosleep(&ts, NULL); }
    uint32_t w = g_pt[k].orig;
    if ((w & 0xFFFFFC1Fu) == 0xD63F0000u) {   // BLR：先取目标再写 x30（BLR x30 时目标是旧 x30）
        int rn = (w >> 5) & 31; uint64_t t = rn < 29 ? ss->__x[rn] : rn == 29 ? ss->__fp : rn == 30 ? ss->__lr : 0;
        ss->__lr = (uint64_t)(uintptr_t)(pc + 1);
        __darwin_arm_thread_state64_set_pc_fptr(*ss, (void *)(uintptr_t)t);
        return 1;
    }
    if ((w >> 26) == 0x25 || (w >> 26) == 0x05) {   // BL：x30 = pc + 4，跳到目标；B：只跳
        int32_t imm = (int32_t)(w & 0x3FFFFFF); if (imm & 0x2000000) imm -= 0x4000000;
        if ((w >> 26) == 0x25) ss->__lr = (uint64_t)(uintptr_t)(pc + 1);
        __darwin_arm_thread_state64_set_pc_fptr(*ss, (void *)(pc + imm));
        return 1;
    }
    int rt = w & 31, rn = (w >> 5) & 31, rt2 = (w >> 10) & 31, x64 = (w >> 31) & 1; int32_t imm7 = (int32_t)((w >> 15) & 0x7F); if (imm7 & 0x40) imm7 -= 0x80;
    uint64_t base = rn == 31 ? __darwin_arm_thread_state64_get_sp(*ss) : rn == 29 ? ss->__fp : rn == 30 ? ss->__lr : ss->__x[rn];
    uint64_t v1, v2;
    if (x64) { const uint64_t *a = (const uint64_t *)(uintptr_t)(base + (int64_t)imm7 * 8); v1 = a[0]; v2 = a[1]; }
    else { const uint32_t *a = (const uint32_t *)(uintptr_t)(base + (int64_t)imm7 * 4); v1 = a[0]; v2 = a[1]; }
    // 线程状态里 x0–x28 在 __x[]，x29 / x30 是 __fp / __lr（__x 只有 29 格，写 __x[29] 越界）；31 是零寄存器
    int rr[2] = {rt, rt2}; uint64_t vv[2] = {v1, v2};
    for (int i = 0; i < 2; i++) { if (rr[i] < 29) ss->__x[rr[i]] = vv[i]; else if (rr[i] == 29) ss->__fp = vv[i]; else if (rr[i] == 30) ss->__lr = vv[i]; }
    __darwin_arm_thread_state64_set_pc_fptr(*ss, (void *)(pc + 1));
    return 1;
}
#endif
