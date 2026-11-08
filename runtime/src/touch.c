// 写跟踪 A 方案的原生层一半（graphics/track/track.c「GPU 改过页的 CPU 首写」）：游戏代码写到 GPU 改过的页时，不在信号处理里调托管代码，
// 而是把这条线程改道到宿主正常上下文：存下缺页时整套寄存器（通用 + 向量 + 状态），pc → sw_touch_tramp（entry.S）、sp → 宿主帧，
// 跳板调 s2a_track_touch（经 C# 回调让 Ryujinx 当场回写 GPU 数据），再 brk 陷入，SIGTRAP 处理把存下的寄存器原样放回、重执行那条写。
// 宿主帧：有切栈槽的线程同门（entry.S sw_gate）在槽游标下开帧并推游标；没有槽的（主线程）就地在当前栈下开帧（同门「不切」分支）。
#include "native.h"
#include <mach/mach_time.h>
#include <signal.h>
#include <sys/ucontext.h>
#include "../../graphics/track/s2a_track.h"

extern void sw_touch_tramp(void); extern const uint32_t sw_touch_brk[];
extern uint64_t g_xs_key;
typedef struct { uint64_t cur, top, bottom, gtop; } xs_slot;   // = xstack.c
// 每线程保存区：线程初始化时（s2a_crash_thread_init）预先分配、经 pthread 键取——信号处理里不碰 __thread（macOS 首次访问惰性分配、调 malloc）
typedef struct { int active; _STRUCT_ARM_THREAD_STATE64 ss; _STRUCT_ARM_NEON_STATE64 ns; xs_slot *slot; uint64_t old_cur, touched, dn, dns; } touch_save;   // dn / dns：诊断计数（改道回写次数、累计 mach 时）
static pthread_key_t g_tkey;
__attribute__((constructor)) static void tkey_init(void) { if (pthread_key_create(&g_tkey, free)) die("touch：pthread_key_create 失败"); }
void s2a_touch_thread_init(void) { if (!pthread_getspecific(g_tkey)) pthread_setspecific(g_tkey, calloc(1, sizeof(touch_save))); }
uint64_t s2a_touch_skip(void) { touch_save *t = pthread_getspecific(g_tkey); return t ? t->touched : 0; }   // 本线程刚回写过的页（track.c 不反复改道）
void s2a_touch_clear(void) { touch_save *t = pthread_getspecific(g_tkey); if (t) t->touched = 0; }

int s2a_touch_redirect(void *ctx, uint64_t addr) {   // 信号处理里调：1 = 已改道
    ucontext_t *uc = ctx; touch_save *ts = pthread_getspecific(g_tkey);
    if (!ts || ts->active) return 0;   // 没预分配（非游戏线程）/ 跳板里又缺页：不改道，调用方走原路径
    ts->ss = uc->uc_mcontext->__ss; ts->ns = uc->uc_mcontext->__ns;
    uint64_t sp = uc->uc_mcontext->__ss.__sp, frame;
    xs_slot *s = pthread_getspecific((pthread_key_t)g_xs_key);
    if (s && (sp > s->top || sp <= s->bottom)) { ts->slot = s; ts->old_cur = s->cur; frame = (s->cur - 256) & ~15ull; s->cur = frame; }
    else { ts->slot = NULL; frame = (sp - 512) & ~15ull; }   // 没槽 / 已在宿主栈：就地开帧（留 512 字节不碰游戏的活数据）
    uc->uc_mcontext->__ss.__x[0] = addr;
    uc->uc_mcontext->__ss.__sp = frame;
    uc->uc_mcontext->__ss.__fp = 0;
    uc->uc_mcontext->__ss.__lr = 0;
    uc->uc_mcontext->__ss.__pc = (uint64_t)sw_touch_tramp;
    ts->touched = addr; ts->active = 1; return 1;
}
int s2a_touch_brk(void *ctx) {   // SIGTRAP 里调：是跳板的 brk 就恢复缺页时的现场，返回 1
    ucontext_t *uc = ctx; touch_save *ts = pthread_getspecific(g_tkey);
    if (!ts || !ts->active || uc->uc_mcontext->__ss.__pc != (uint64_t)sw_touch_brk) return 0;
    if (ts->slot) ts->slot->cur = ts->old_cur;
    uc->uc_mcontext->__ss = ts->ss; uc->uc_mcontext->__ns = ts->ns;
    ts->active = 0; return 1;
}
// 回写要经 C# 让 Ryujinx 当场读回 GPU 数据（几～几十 ms）：期间放开虚拟核（S2A_CORES，thread.c），回游戏前取回——
// 跳板已把线程改道到宿主正常上下文（不在信号处理里），放 / 取核可以照常加锁（修干净清单 #12，原生层线 10-20 指出）
void s2a_core_leave(void), s2a_core_enter(void);
void s2a_touch_body(uint64_t addr) {
    uint64_t t0 = mach_absolute_time();
    s2a_core_leave(); s2a_track_touch(addr); s2a_core_enter();
    touch_save *ts = pthread_getspecific(g_tkey); if (ts) { ts->dn++; ts->dns += mach_absolute_time() - t0; }   // 诊断打点用：本线程改道回写次数 / 耗时
}
// 诊断打点用（diag_brk.c，信号里可调）：本线程改道回写累计次数与 mach 时
uint64_t s2a_touch_stat(uint64_t *mach) { touch_save *ts = pthread_getspecific(g_tkey); if (!ts) { *mach = 0; return 0; } *mach = ts->dns; return ts->dn; }
