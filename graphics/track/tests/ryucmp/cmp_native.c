// 对拍工具的原生一半：信号处理（先给写跟踪，不是它的页交回 .NET 运行时原先的处理）、真内存分配、按字节写
#include "../../s2a_track.h"
#include <signal.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/ucontext.h>
#include <stdint.h>
static struct sigaction g_old_bus, g_old_segv;
static void on_sig(int s, siginfo_t *si, void *uc) {
    int wnr = uc ? (int)(((ucontext_t *)uc)->uc_mcontext->__es.__esr >> 6 & 1) : 1;
    if (s2a_track_fault(si->si_addr, wnr)) return;
    struct sigaction *o = s == SIGBUS ? &g_old_bus : &g_old_segv;
    if (o->sa_flags & SA_SIGINFO) o->sa_sigaction(s, si, uc); else if (o->sa_handler != SIG_DFL && o->sa_handler != SIG_IGN) o->sa_handler(s); else { signal(s, SIG_DFL); raise(s); }
}
void cmp_install(void) {
    struct sigaction sa; memset(&sa, 0, sizeof sa); sa.sa_sigaction = on_sig; sa.sa_flags = SA_SIGINFO | SA_ONSTACK; sigemptyset(&sa.sa_mask);
    sigaction(SIGBUS, &sa, &g_old_bus); sigaction(SIGSEGV, &sa, &g_old_segv);
}
void *cmp_alloc(uint64_t n) { void *p = mmap(NULL, n, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); return p == MAP_FAILED ? 0 : p; }
void cmp_write(uint64_t a, const uint8_t *v, int n) { volatile uint8_t *d = (volatile uint8_t *)a; for (int i = 0; i < n; i++) d[i] = v[i]; }   // 游戏 CPU 写：只读页上缺页
void cmp_write_untracked(uint64_t a, const uint8_t *v, int n, int flush) { s2a_track_write_untracked(a, v, (uint64_t)n, flush); }
