// 直连模式的系统层接点（10-24 双轨，原生层线；接口与语义见 runtime/include/s2a_direct_host.h）。
// 缺页钩子在信号里读：指针用原子、release 发布 / acquire 读；每个登记口只收一个回调
#include "native.h"
#include "../include/s2a_direct_host.h"
#include "../../graphics/track/s2a_track.h"
#include <stdatomic.h>

static _Atomic(s2a_fault_hook_fn) g_fault;
static _Atomic(s2a_guest_write_prep_fn) g_prep;
static _Atomic(void (*)(void)) g_wait_dump, g_res_report;
static _Atomic(void (*)(int)) g_summary;

#define ONE(slot, fn, what) do { void *old_ = (void *)atomic_load(&(slot)); \
    if (old_ && old_ != (void *)(fn)) die("%s：已经登记了另一个回调（只许一个主人）", what); \
    atomic_store_explicit(&(slot), (fn), memory_order_release); } while (0)

void s2a_fault_hook_register(s2a_fault_hook_fn fn) { ONE(g_fault, fn, "s2a_fault_hook_register"); }
// crash.c 信号处理调（两条分支都最先问）：1 = 钩子认领了这一页
int s2a_direct_fault(void *addr, int is_write, void *uctx) {
    s2a_fault_hook_fn f = atomic_load_explicit(&g_fault, memory_order_acquire);
    return f ? f(addr, is_write, uctx) : 0;
}
void s2a_guest_write_prep_register(s2a_guest_write_prep_fn fn) { ONE(g_prep, fn, "s2a_guest_write_prep_register"); s2a_track_set_write_prep(fn); }
void s2a_crash_wait_dump_register(void (*fn)(void)) { ONE(g_wait_dump, fn, "s2a_crash_wait_dump_register"); }
void s2a_res_report_register(void (*fn)(void)) { ONE(g_res_report, fn, "s2a_res_report_register"); }
void s2a_direct_wait_dump(void) { void (*f)(void) = atomic_load_explicit(&g_wait_dump, memory_order_acquire); if (f) f(); }
void s2a_direct_res_report(void) { void (*f)(void) = atomic_load_explicit(&g_res_report, memory_order_acquire); if (f) f(); }

void s2a_direct_summary_register(void (*fn)(int)) { ONE(g_summary, fn, "s2a_direct_summary_register"); }
void s2a_direct_summary(int normal) { void (*f)(int) = atomic_load_explicit(&g_summary, memory_order_acquire); if (f) f(normal); }
void s2a_direct_host_session_reset(void) {
    atomic_store(&g_fault, NULL); atomic_store(&g_prep, NULL);
    atomic_store(&g_wait_dump, NULL); atomic_store(&g_res_report, NULL);
    atomic_store(&g_summary, NULL); s2a_track_set_write_prep(NULL);
}
